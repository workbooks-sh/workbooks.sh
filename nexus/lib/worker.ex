defmodule Nexus.Worker do
  @moduledoc """
  The `worker` kind — a long-lived, SUPERVISED background process declared in `.work`.

  Where a `flow`'s `parallel` group is *transient* fan-out (Task: spawn, gather, done) and a `hook
  trigger`/`Nexus.Scheduler` fires *stateless* effects on a clock, a `worker` is the missing third
  shape: a *stateful, always-on* process — the GenServer concept — surfaced as authored vocabulary.
  An author declares the lifecycle; the runtime owns the OTP:

      worker :indexer, every: "30s" do
        def init, do: %{indexed: 0}              # initial in-process state
        def tick(state) do                       # called every `every:`; returns the next state
          n = reindex_changed()
          %{state | indexed: state.indexed + n}
        end
      end

  The author never writes `GenServer`, `start_link`, `handle_info`, or a supervisor — they write
  `init/0` (seed state) and `tick/1` (state → state). This module is the generic GenServer HOST that
  drives those callbacks; workers run under `Nexus.Worker.Supervisor` (a DynamicSupervisor in the
  nexus tree), so a crash RESTARTS per the declared `restart:` policy (default `:permanent`). Same
  OTP family as `Nexus.Scheduler` — BEAM process supervision as a `.work` declaration.

  Lifecycle: `compile/1` (the compile pass) turns a `worker` unit into a BEAM module + a registered
  spec; `start_all/0` (called from the serving bringup) starts each registered spec under supervision.
  Compiling does NOT start anything, so `mix test` / pure compiles never spawn loops.
  """
  use GenServer
  require Logger

  @reg {__MODULE__, :specs}
  @sup __MODULE__.Supervisor
  @registry __MODULE__.Registry

  # ── supervision tree wiring ───────────────────────────────────────────────────────────────────

  @doc "Child specs for the app tree: the worker registry + the DynamicSupervisor workers live under."
  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @sup, strategy: :one_for_one}
    ]
  end

  # ── compile pass: unit → module + registered spec (no process started) ────────────────────────

  @doc """
  Compile a parsed `worker` unit: build its BEAM module (its `def init`/`def tick` body) and register
  a spec under its name. Returns the spec. Does NOT start the process — `start_all/0` does that in a
  serving context. A later compile of the same name REPLACES the spec (re-armed on the next bringup).
  """
  def compile(%{kind: "worker", name: name} = node) do
    case Nexus.Unit.compile(node) do
      {:ok, module} ->
        o = opts(node)

        spec = %{
          name: to_string(name),
          module: module,
          interval_ms: interval_ms(o),
          restart: restart(o)
        }

        register(spec)
        spec

      {:error, reason} ->
        raise "worker #{name} won't compile: #{inspect(reason)}"
    end
  end

  def compile(_), do: nil

  defp register(%{name: name} = spec),
    do: :persistent_term.put(@reg, Map.put(specs_map(), name, spec))

  @doc "All registered worker specs."
  def specs, do: specs_map() |> Map.values()

  defp specs_map, do: :persistent_term.get(@reg, %{})

  # `every:` → tick interval in ms (nil = no periodic tick, a one-shot daemon that just holds state).
  defp interval_ms(o) do
    case o[:every] do
      nil -> nil
      v -> case Nexus.Time.duration_ms(v), do: ({:ok, ms} -> ms; :error -> nil)
    end
  end

  # `restart:` → OTP restart policy. Default :permanent (always restart — it's a daemon).
  defp restart(o) when is_list(o) do
    case o[:restart] do
      r when r in [:permanent, :transient, :temporary] -> r
      _ -> :permanent
    end
  end

  # the keyword opts of a `worker :name, every: "…" do … end` node (between the name and the do-block)
  defp opts(%{ast: {_kind, _meta, args}}) when is_list(args) do
    Enum.find(args, [], &Keyword.keyword?/1)
  end

  defp opts(_), do: []

  # ── starting workers under supervision (serving bringup) ──────────────────────────────────────

  @doc "Start every registered worker under supervision (idempotent — replaces a running same-named one)."
  def start_all do
    for spec <- specs() do
      case start(spec) do
        {:ok, _pid} -> :ok
        {:error, reason} -> Logger.warning("[worker] #{spec.name} failed to start: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc "Start (or restart) one worker spec under the DynamicSupervisor."
  def start(%{name: name} = spec) do
    stop(name)
    DynamicSupervisor.start_child(@sup, child_spec(spec))
  end

  @doc "Stop a running worker by name (no-op if not running)."
  def stop(name) do
    case pid(name) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@sup, pid)
    end
  end

  @doc "Pid of a running worker by name, or nil."
  def pid(name) do
    case Registry.lookup(@registry, to_string(name)) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  @doc "Names of currently-running workers."
  def running, do: Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  defp child_spec(%{name: name, restart: restart} = spec) do
    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [spec]},
      restart: restart
    }
  end

  def start_link(%{name: name} = spec),
    do: GenServer.start_link(__MODULE__, spec, name: {:via, Registry, {@registry, to_string(name)}})

  # ── the generic GenServer host ────────────────────────────────────────────────────────────────

  @impl true
  def init(%{module: module, interval_ms: ms} = spec) do
    state = if function_exported?(module, :init, 0), do: module.init(), else: %{}
    if ms, do: schedule(ms)
    {:ok, %{spec: spec, state: state}}
  end

  @impl true
  def handle_info(:tick, %{spec: %{module: module, interval_ms: ms, name: name}, state: state} = s) do
    # A bad TICK keeps the daemon alive on its prior state (one poll failing shouldn't tear down a
    # long-lived worker and reset it — and a tight crash-loop would otherwise trip the supervisor's
    # max-restart limit). Genuine process death (a kill, an init crash) still restarts via OTP.
    next =
      try do
        if function_exported?(module, :tick, 1), do: module.tick(state), else: state
      rescue
        e ->
          Logger.warning("[worker] #{name} tick crashed: #{Exception.message(e)} — keeping prior state")
          state
      end

    if ms, do: schedule(ms)
    {:noreply, %{s | state: next}}
  end

  def handle_info(_other, s), do: {:noreply, s}

  @doc "Introspect a running worker's current state (for tests + a future dashboard view)."
  @impl true
  def handle_call(:state, _from, s), do: {:reply, s.state, s}

  @doc "Read a running worker's current in-process state by name, or nil if not running."
  def state(name) do
    case pid(name) do
      nil -> nil
      pid -> GenServer.call(pid, :state)
    end
  end

  defp schedule(ms), do: Process.send_after(self(), :tick, ms)
end
