defmodule Workbooks.Keeper do
  @moduledoc """
  Runtime-native keeper scheduler (wb-5vm / lander-live).

  Runs an agent def on a timer, entirely on-box — needed when the control plane
  is internal-only and GitHub-cron can't reach it over a public URL.

  ## Env contract

    - `WB_KEEPER_DEF`         — path to an Org agent def file. **Required** to
                                activate the keeper; when unset the GenServer
                                starts but stays idle indefinitely.
    - `WB_KEEPER_INTERVAL_MS` — tick interval in ms (default: 3_600_000 = 1h).
                                First tick fires after one interval, not on boot.
    - `WB_KEEPER_MODE`        — `plan` (default) or `edit`. `plan` = the agent
                                only critiques + updates its backlog, never edits
                                the page (for watched early runs). Passed into
                                the task line; the def enforces it.
    - `WB_TENANT`             — the tenant whose git repo the keeper works in
                                (default "local"); the run's workdir is that repo,
                                so the keeper's commits ARE the public changelog.
    - `WB_LIFECYCLE_DEF`      — OPTIONAL path to a lifecycle state-machine spec
                                (see `Workbooks.Keeper.Lifecycle`). When set and
                                parseable, the keeper consults it for what each
                                tick IS (`wake_add | wake_audit | rem`) instead of
                                relying on count-based prose in the agent def: a
                                `wake` state runs the def with the state PREPENDED
                                to the task line; a `rem` state skips the run and
                                dreams directly. Unset / unparseable → exactly the
                                env+prose behavior below (zero regression).

  `Workbooks.Keeper.run_once/0` triggers one tick immediately (for a watched
  manual validation run, e.g. over `fly ssh`).

  ## Isolation

  Belongs entirely to the HOST layer: reads a loaded artifact (the .org def) but
  never calls into the PUBLIC plane, never touches the Dock membrane, and the run
  uses the same `AgentDef.run/3` path as `POST /api/brandnana-ask`. Crash-safe:
  a failed tick logs the error and reschedules the next tick; the supervisor is
  never brought down.
  """
  use GenServer
  require Logger

  @default_interval_ms 3_600_000

  # ── public API ──────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Trigger one keeper tick immediately (watched manual validation run)."
  def run_once, do: send(__MODULE__, :tick)

  @doc """
  Live keeper status for the public plane (read via `:persistent_term`, never a
  GenServer call — ticks run synchronously in the GenServer, so a call would
  block for the whole run). Times are unix seconds; `next_run` is best-effort
  (last schedule + interval).
  """
  def status do
    base =
      :persistent_term.get({__MODULE__, :status}, %{
        active: false,
        running: false,
        last_run: nil,
        next_run: nil,
        interval_ms: nil
      })

    # Surface the declared lifecycle position when a spec is active; nil otherwise
    # (read straight through to /_activity, which returns status verbatim).
    Map.put(base, :lifecycle, Workbooks.Keeper.Lifecycle.status())
  end

  defp put_status(patch) do
    :persistent_term.put({__MODULE__, :status}, Map.merge(status(), patch))
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # Runs execute in a linked Task (see :tick) so they can be killed on
    # timeout; trap exits so a crashing run never takes the keeper down.
    Process.flag(:trap_exit, true)

    case def_path() do
      nil ->
        Logger.info("Keeper: WB_KEEPER_DEF not set — idle")
        {:ok, %{active: false}}

      path ->
        # Catch-up scheduling: restarts must not reset the cadence clock. The
        # last tick time persists on the data volume; if a full interval has
        # already elapsed (or we've never run), tick ~60s after boot instead
        # of waiting a whole fresh interval.
        delay = next_delay_ms()
        Logger.info("Keeper: activated — def=#{path} interval=#{interval_ms()}ms first-tick-in=#{delay}ms")
        Process.send_after(self(), :tick, delay)

        put_status(%{
          active: true,
          running: false,
          interval_ms: interval_ms(),
          last_run: read_last_run(),
          next_run: System.system_time(:second) + div(delay, 1000)
        })

        {:ok, %{active: true, def_path: path}}
    end
  end

  @impl true
  def handle_info(:tick, %{active: false} = state), do: {:noreply, state}

  def handle_info(:tick, %{def_path: path} = state) do
    write_last_run()
    put_status(%{running: true, last_run: System.system_time(:second)})

    # When a lifecycle spec is active it decides what THIS tick is (wake vs rem,
    # and which wake state); otherwise we fall back to the env+prose path exactly
    # as before (zero regression when WB_LIFECYCLE_DEF is unset). wb-2ku.3.
    run_tick(path, Workbooks.Keeper.Lifecycle.current())

    schedule()
    put_status(%{running: false, next_run: System.system_time(:second) + div(interval_ms(), 1000)})
    {:noreply, state}
  end

  # trap_exit is on: absorb EXITs from run tasks (normal or killed).
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # ── tick dispatch ─────────────────────────────────────────────────────────────

  # No lifecycle spec → original behavior: run the def, then maybe-dream (the
  # time gate lives in Dreams). The agent def decides add-vs-audit from prose.
  defp run_tick(path, nil) do
    Logger.info("Keeper: tick — running #{path}")
    wake(path, nil)
    # REM: after waking work, maybe dream (time-gated, fire-and-forget — a failed
    # or slow dream can never touch the run loop). wb-2ku.
    Task.start(fn -> Workbooks.Dreams.maybe_dream(System.get_env("WB_TENANT", "local")) end)
  end

  # A gated state (rem before its min-interval elapsed, say) → no-op tick that
  # holds cadence position: advance(:done) is NOT called, so we re-evaluate the
  # same state next tick once the gate opens.
  defp run_tick(_path, %{gated: true, state: s}) do
    Logger.info("Keeper: tick — #{s} gated (min-interval not elapsed), holding position")
  end

  # rem state: skip the agent run; dream directly (the time gate now lives in the
  # spec, not Dreams). A successful dream advances the lifecycle; a failed one
  # holds position (retry next tick).
  defp run_tick(_path, %{kind: :rem, state: s}) do
    Logger.info("Keeper: tick — #{s} (rem) dreaming")
    Workbooks.Keeper.Lifecycle.mark_ran(s)

    outcome =
      try do
        Workbooks.Dreams.dream(System.get_env("WB_TENANT", "local"))
        :done
      rescue
        e ->
          Logger.error("Keeper: rem tick failed — #{Exception.message(e)}")
          :failed
      end

    Workbooks.Keeper.Lifecycle.advance(outcome)
  end

  # wake state: run the def with the lifecycle state PREPENDED to the task line,
  # so the def no longer needs count-based prose to choose add vs audit.
  defp run_tick(path, %{kind: :wake, state: s}) do
    Logger.info("Keeper: tick — #{s} (wake) running #{path}")
    Workbooks.Keeper.Lifecycle.mark_ran(s)
    Workbooks.Keeper.Lifecycle.advance(wake(path, s))
  end

  # Run the agent def under the wall-clock bound; returns the tick OUTCOME
  # (:done | :failed | :killed) for the lifecycle to step on. `lifecycle_state`
  # (nil in the env+prose path) is prepended to the task line when present.
  defp wake(path, lifecycle_state) do
    task = Task.async(fn -> run_def(File.read!(path), lifecycle_state) end)

    case Task.yield(task, run_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        Logger.info("Keeper: tick done — #{inspect(String.slice(result.result || "", 0, 120))}")
        :done

      {:exit, reason} ->
        Logger.error("Keeper: tick failed — #{inspect(reason)}")
        :failed

      nil ->
        Logger.error("Keeper: tick killed — exceeded #{run_timeout_ms()}ms wall clock")
        :killed
    end
  end

  # ── private helpers ──────────────────────────────────────────────────────────

  defp def_path, do: System.get_env("WB_KEEPER_DEF")

  # ── cadence persistence (survives restarts/redeploys) ───────────────────────

  defp last_run_path, do: Path.join(System.get_env("WB_DATA") || File.cwd!(), "keeper-last-run")

  defp write_last_run do
    File.write(last_run_path(), Integer.to_string(System.system_time(:second)))
  rescue
    _ -> :ok
  end

  defp read_last_run do
    with {:ok, s} <- File.read(last_run_path()), {ts, _} <- Integer.parse(String.trim(s)), do: ts, else: (_ -> nil)
  end

  @boot_grace_ms 60_000

  defp next_delay_ms do
    case read_last_run() do
      nil ->
        @boot_grace_ms

      ts ->
        elapsed_ms = (System.system_time(:second) - ts) * 1000
        max(@boot_grace_ms, interval_ms() - elapsed_ms)
    end
  end

  defp interval_ms do
    case System.get_env("WB_KEEPER_INTERVAL_MS") do
      nil -> @default_interval_ms
      s -> String.to_integer(s)
    end
  end

  @default_run_timeout_ms 900_000

  defp run_timeout_ms do
    case System.get_env("WB_KEEPER_RUN_TIMEOUT_MS") do
      nil -> @default_run_timeout_ms
      s -> String.to_integer(s)
    end
  end

  defp schedule, do: Process.send_after(self(), :tick, interval_ms())

  # Run via AgentDef.run/3 — same path as /api/run. The def's :MODEL: property is
  # honoured by AgentDef.run. The agent gets a shell (exec: true) and a workdir =
  # the tenant's git repo, so it reads/edits/commits the page IN its versioned
  # source of truth and its commits become the public changelog. The task line
  # carries the mode (plan|edit), which the def enforces.
  defp run_def(org, lifecycle_state) do
    mode = System.get_env("WB_KEEPER_MODE", "plan")
    tenant = System.get_env("WB_TENANT", "local")
    workdir = Workbooks.Git.repo_path(tenant)
    Workbooks.Git.ensure_repo(tenant)

    # When the lifecycle is driving, the state IS the add-vs-audit decision —
    # prepend it so the def stops counting commits to decide. Absent → the def's
    # own prose decides (the env+prose fallback).
    lifecycle_line = if lifecycle_state, do: "LIFECYCLE: #{lifecycle_state}\n", else: ""

    Workbooks.AgentDef.run(
      org,
      "MODE: #{mode}\n#{lifecycle_line}Perform one keeper run per your loop. Your working directory is this page's git repo.",
      exec: true,
      workdir: workdir,
      max_steps: 60
    )
  end
end
