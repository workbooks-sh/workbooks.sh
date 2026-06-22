defmodule Nexus.Effects do
  @moduledoc """
  The open **effect registry** — the "do" half of the reactive layer (`#event` → bus → `hook` →
  effects). An effect is a named handler `fn effect_args, event, ctx -> term end`. The set is OPEN:
  the runtime ships generic built-ins (`emit`, `run`, `notify`), and any consumer registers its own
  (e.g. our cloud dashboard registers `log` → a durable `resource :Event` + the Activity page). The
  nexus carries only generic mechanism; no Workbooks business lives here.

  Effects are dispatched by `Nexus.Events` in supervised async tasks (failure-isolated, non-blocking),
  so a slow effect (an agent run!) can't stall the emitter or its sibling effects.
  """
  require Logger

  @reg {__MODULE__, :handlers}

  @doc "Register (or replace) a named effect handler `fn args_map, event, ctx -> term end`."
  def register(name, handler) when is_binary(name) and is_function(handler, 3) do
    :persistent_term.put(@reg, Map.put(handlers(), name, handler))
    :ok
  end

  @doc "All registered effect handlers."
  def handlers, do: :persistent_term.get(@reg, %{})

  @doc "Is `name` a known effect?"
  def known?(name), do: Map.has_key?(handlers(), name)

  @doc """
  Run one effect synchronously (the bus wraps this in a supervised Task). `effect` is
  `%{name: string, args: map}`; `event` is the triggering event; `ctx` carries causation depth +
  tenant for guards. Unknown effects are logged, never raised.
  """
  def run(%{name: name} = effect, event, ctx) do
    case Map.get(handlers(), name) do
      nil ->
        Logger.warning("[effects] no such effect: #{name}")
        {:error, :unknown_effect}

      handler ->
        handler.(Map.get(effect, :args, %{}), event, ctx)
    end
  end

  @doc """
  Install the generic built-in effects. Called once at boot. Idempotent (re-registering replaces).
  Consumers (cloud dashboard, agents) register additional effects on top.
  """
  def install_builtins do
    # `emit` — chain a new event back onto the bus (loop-guarded by Nexus.Events via ctx depth).
    register("emit", fn args, _event, ctx ->
      Nexus.Events.emit(args, depth: Map.get(ctx, :depth, 0) + 1, tenant: Map.get(ctx, :tenant))
    end)

    # `notify` — generic notification sink. Default is a log line; richer sinks (toast/email) register
    # over this name in their own context. Stays neutral in the open standard.
    register("notify", fn args, event, _ctx ->
      Logger.info("[notify] #{args[:title] || event[:title] || event[:kind] || "event"}")
      :ok
    end)

    # `autopoet.cycle` — the autopoet heartbeat effect: the scheduled beat runs one SENSE→DECIDE→ACT→
    # LEARN cycle. Armed/disarmed by admin via Nexus.Autopoet.Worker (opt-in; never on by default).
    register("autopoet.cycle", fn _args, _event, _ctx ->
      Nexus.Autopoet.Worker.run_once()
      :ok
    end)

    # `run` / `call` — invoke an agent or a flow as a side effect (through the normal, capability-gated
    # paths). `args`: %{agent: "name", task: "..."} → Nexus.Agent.run; %{flow: "name"} → Nexus.Flow.run.
    #
    # SECURITY (wb-v9yp): there is deliberately NO raw `mfa: {Mod,Fun,Args}` branch. A hook compiles
    # from any authored `.work`, so an `mfa` escape hatch let a hook author run `apply(System,:cmd,…)`
    # — arbitrary native Elixir on the host BEAM, outside every sandbox/tenant/grant (host RCE). Effects
    # may only invoke the named, capability-gated runtimes (agents/flows), never an arbitrary MFA. The
    # firing event's `tenant` is threaded through so the run is scoped to that tenant (wb-j05s).
    runner = fn args, event, ctx ->
      tenant = ctx[:tenant]

      cond do
        is_binary(args[:flow]) ->
          Nexus.Flow.run(args[:flow], args[:input] || event[:title] || event[:kind] || "", ctx)

        is_binary(args[:agent]) ->
          task = args[:task] || event[:title] || event[:kind] || ""
          # resolve a DECLARED agent (its prompt/tools/grant/limit); fall back to an ad-hoc run.
          case Nexus.Agent.get(args[:agent]) do
            nil -> Nexus.Agent.run(task: task, unit: args[:agent], tenant: tenant)
            node -> Nexus.Agent.run_unit(node, task, tenant: tenant)
          end

        true ->
          {:error, :run_needs_agent_or_flow}
      end
    end

    register("run", runner)
    register("call", runner)
    :ok
  end
end
