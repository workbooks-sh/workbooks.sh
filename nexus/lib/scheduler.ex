defmodule Nexus.Scheduler do
  @moduledoc """
  The **time-driven trigger** for the reactive layer — the temporal sibling of `Nexus.Events`.
  Where the event bus fires `hook` effects in reaction to *events*, the scheduler fires effects in
  reaction to *time*: a `trigger every:/cron:/at:` on a `hook`, a delayed `flow` step, a `task`
  `SCHEDULED:`. It is the one place `Process.send_after` lives.

  ## Model

  An armed entry is `%{name, tenant, spec, effects}` where `spec` is a `Nexus.Time` spec and
  `effects` is a list of `%{name, args}` resolved against the open `Nexus.Effects` registry — the
  SAME effects a `hook` runs, so a schedule reuses `run agent:`/`run flow:`/`emit`/`notify` with no
  parallel dispatch path. On fire we run each effect in a supervised Task (failure-isolated), then
  re-arm if the spec repeats (`every`/`cron`/`at`/timestamp-with-repeater) or drop it if it was
  one-shot (`after`/a plain timestamp).

  ## Durability — source IS the schedule

  Schedules are declared in `.work` (a `hook`'s `trigger`, a `flow` step, a `task` deadline), so the
  blocks ARE the source of truth (no JSON sidecar, no runtime table). The compile pipeline re-arms
  every declared trigger at boot via `Nexus.Compile`, so a restart faithfully restores the schedule
  from source. `arm/4` is idempotent per `{tenant, name}` (re-arming replaces), so recompiling a
  changed `.work` cleanly updates the live timer.

  Tenant-scoped (one nexus per org) and loop-safe: a fired `emit` enters the bus at depth 1, so the
  existing `Nexus.Events` depth guard still bounds any schedule → event → hook → … cascade.
  """
  use GenServer
  require Logger

  @tasksup Nexus.Scheduler.TaskSup
  @default_tenant "default"

  # ── lifecycle ─────────────────────────────────────────────────────────────────────────────────

  @doc "Child specs for the supervision tree — the scheduler GenServer + its Task.Supervisor."
  def child_specs do
    [
      {Task.Supervisor, name: @tasksup},
      __MODULE__
    ]
  end

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  # ── public API ────────────────────────────────────────────────────────────────────────────────

  @doc """
  Arm (or replace) a named schedule. `time` is anything `Nexus.Time.spec/1` accepts (a keyword
  like `[every: "15m"]` / `[cron: "0 2 * * *"]`, or an org `<…>` string). `effects` is a list of
  `%{name, args}` effect maps. Opts: `:tenant`. Returns `:ok` or `{:error, reason}`.
  """
  def arm(name, time, effects, opts \\ []) do
    case Nexus.Time.spec(time) do
      {:ok, spec} -> GenServer.call(__MODULE__, {:arm, key(name, opts), spec, List.wrap(effects)})
      {:error, _} = err -> err
    end
  end

  @doc "Disarm a schedule by name (cancels its pending timer). Always `:ok`."
  def disarm(name, opts \\ []), do: GenServer.call(__MODULE__, {:disarm, key(name, opts)})

  @doc "List armed entries (optionally for one `:tenant`)."
  def list(opts \\ []) do
    case GenServer.call(__MODULE__, :list) do
      entries when is_list(entries) ->
        case opts[:tenant] do
          nil -> entries
          t -> Enum.filter(entries, &(&1.tenant == t))
        end
    end
  end

  @doc "Fire a schedule's effects right now (does not affect its timer). For tests + manual runs."
  def fire_now(name, opts \\ []), do: GenServer.call(__MODULE__, {:fire_now, key(name, opts)})

  @doc "Drop every armed schedule (cancels all timers). For tests."
  def clear, do: GenServer.call(__MODULE__, :clear)

  # ── GenServer ─────────────────────────────────────────────────────────────────────────────────

  @impl true
  def init(_), do: {:ok, %{entries: %{}, timers: %{}}}

  @impl true
  def handle_call({:arm, k, spec, effects}, _from, state) do
    state = cancel(state, k)
    entry = %{name: elem(k, 1), tenant: elem(k, 0), spec: spec, effects: effects}
    state = put_in(state.entries[k], entry)

    case Nexus.Time.ms_until(spec) do
      :none ->
        # nothing in the future (a past one-shot) — keep it listed but un-timed.
        {:reply, :ok, state}

      ms ->
        {:reply, :ok, schedule(state, k, ms)}
    end
  end

  def handle_call({:disarm, k}, _from, state) do
    state = cancel(state, k)
    {:reply, :ok, %{state | entries: Map.delete(state.entries, k)}}
  end

  def handle_call(:list, _from, state), do: {:reply, Map.values(state.entries), state}

  def handle_call({:fire_now, k}, _from, state) do
    case state.entries[k] do
      nil -> {:reply, {:error, :no_schedule}, state}
      entry -> run(entry); {:reply, :ok, state}
    end
  end

  def handle_call(:clear, _from, state) do
    Enum.each(state.timers, fn {ref, _} -> Process.cancel_timer(ref) end)
    {:reply, :ok, %{entries: %{}, timers: %{}}}
  end

  @impl true
  def handle_info({:fire, k}, state) do
    state = %{state | timers: drop_timer(state.timers, k)}

    case state.entries[k] do
      nil ->
        {:noreply, state}

      entry ->
        run(entry)

        if Nexus.Time.repeating?(entry.spec) do
          case Nexus.Time.ms_until(entry.spec) do
            :none -> {:noreply, %{state | entries: Map.delete(state.entries, k)}}
            ms -> {:noreply, schedule(state, k, ms)}
          end
        else
          # one-shot: drop after firing.
          {:noreply, %{state | entries: Map.delete(state.entries, k)}}
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── internals ─────────────────────────────────────────────────────────────────────────────────

  defp key(name, opts), do: {opts[:tenant] || @default_tenant, to_string(name)}

  # Erlang timers cap at ~49.7 days; clamp and let a long sleep re-evaluate on wake.
  @max_ms 4_000_000_000
  defp schedule(state, k, ms) do
    ms = min(ms, @max_ms)
    ref = Process.send_after(self(), {:fire, k}, ms)
    %{state | timers: Map.put(drop_timer(state.timers, k), ref, k)}
  end

  defp cancel(state, k) do
    %{state | timers: drop_timer(state.timers, k)}
  end

  defp drop_timer(timers, k) do
    case Enum.find(timers, fn {_ref, kk} -> kk == k end) do
      {ref, _} -> Process.cancel_timer(ref); Map.delete(timers, ref)
      nil -> timers
    end
  end

  # Run each of the entry's effects in a supervised task. The synthetic event carries the schedule's
  # identity + a fresh causation depth (0 → an `emit` lands at depth 1, inside the bus loop guard).
  defp run(%{name: name, tenant: tenant, effects: effects}) do
    event = %{kind: "schedule", title: name, tenant: tenant, at: System.os_time(:second)}
    ctx = %{depth: 0, tenant: tenant, source: :scheduler}

    Enum.each(effects, fn effect ->
      Task.Supervisor.start_child(@tasksup, fn ->
        try do
          Nexus.Effects.run(effect, event, ctx)
        rescue
          e -> Logger.warning("[scheduler] #{name} effect #{inspect(effect[:name])} crashed: #{Exception.message(e)}")
        end
      end)
    end)
  end
end
