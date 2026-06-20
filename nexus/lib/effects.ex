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

    # `run` / `call` — invoke an agent or a unit function as a side effect (through the normal paths).
    # `args`: %{agent: "name", task: "..."} → Nexus.Agent.run; or %{mfa: {Mod, :fun, [args]}} → apply.
    runner = fn args, event, _ctx ->
      cond do
        is_binary(args[:agent]) ->
          task = args[:task] || event[:title] || event[:kind] || ""
          Nexus.Agent.run(task: task, unit: args[:agent])

        match?({m, f, a} when is_atom(m) and is_atom(f) and is_list(a), args[:mfa]) ->
          {m, f, a} = args[:mfa]
          apply(m, f, a)

        true ->
          {:error, :run_needs_agent_or_mfa}
      end
    end

    register("run", runner)
    register("call", runner)
    :ok
  end
end
