defmodule Workbooks.Keeper.Worker do
  @moduledoc """
  The INSTANTIABLE keeper core (wb-wc0.2). This is the engine that used to live
  inline in `Workbooks.Keeper`; it was lifted out verbatim and parameterized so
  ONE implementation serves both:

    * the SINGLETON keeper (the lander) — started by `Workbooks.Keeper` with the
      legacy config (def from `WB_KEEPER_DEF`, UNNAMESPACED persistence keys
      `keeper-last-run` / `lifecycle-pos`, persistent_term status key
      `{Workbooks.Keeper, :status}`, no agent label). Zero behavior change.
    * a CREW WORKER (bit.ml) — one instance per crew member, each with its own
      def, its own lifecycle ctx, and persistence keys namespaced by agent name
      (`keeper-last-run-<name>`, `lifecycle-pos-<name>`, status key
      `{Workbooks.Keeper, :status, <name>}`). So N agents tick independently with
      no shared cadence state.

  ## Config (`%Cfg{}`)

    * `name`           — the registered GenServer name (an atom or via-tuple).
    * `agent`          — the agent's display name (a string), or nil for the
      singleton. Threaded into the agent run so each STEP and THOUGHT carries the
      agent's identity (per-agent activity, wb-wc0.2 §3).
    * `def_path`       — the agent Org def to run each wake tick.
    * `lifecycle_ctx`  — a `Workbooks.Keeper.Lifecycle.Ctx` (spec path + ns), or
      nil → no lifecycle, env+prose path.
    * `key_suffix`     — persistence namespace suffix ("" for the singleton,
      "-<name>" for a crew worker). Applied to `keeper-last-run` + the status
      persistent_term key.
    * `interval_ms` / `run_timeout_ms` / `continuous` / `breather_ms` —
      per-worker cadence, each read from env for the singleton but explicit for a
      crew worker (its manifest :INTERVAL: wins).
    * `acquire` / `release` — a 0/1-arity pair the worker calls around each run to
      respect the crew's GLOBAL concurrency cap (`Workbooks.Keeper.Crew.Gate`).
      The singleton passes no-ops (it is the only runner).

  Crash-safety, wall-clock bound, no_work mapping, continuous mode, catch-up
  scheduling — all unchanged from the original singleton keeper.

  ## Board claims are a DEF-LEVEL protocol, not runtime-enforced

  When several crew agents share a task board, "claiming" a task (so two agents
  don't grab the same one) is the AGENTS' protocol — a board state change plus an
  `:AGENT:` property the agent commits BEFORE doing the work, visible to peers in
  git. The runtime does NOT lock tasks; it only ISOLATES runs (each worker its own
  workdir/state, the global cap throttling concurrency). Coordination correctness
  lives in the def + the board, exactly where the non-deterministic interior of a
  state already lives.
  """
  use GenServer
  require Logger

  alias Workbooks.Keeper.Lifecycle

  @default_interval_ms 3_600_000
  @default_run_timeout_ms 900_000
  @boot_grace_ms 60_000

  defmodule Cfg do
    @moduledoc false
    defstruct name: nil,
              agent: nil,
              def_path: nil,
              lifecycle_ctx: nil,
              key_suffix: "",
              interval_ms: nil,
              run_timeout_ms: nil,
              continuous: false,
              breather_ms: 45_000,
              start_delay_ms: 0,
              acquire: nil,
              release: nil
  end

  # ── public API ──────────────────────────────────────────────────────────────

  def start_link(%Cfg{name: name} = cfg) do
    GenServer.start_link(__MODULE__, cfg, name: name)
  end

  @doc "Trigger one tick immediately on a worker (watched manual validation run)."
  def run_once(server), do: send(server, :tick)

  @doc """
  Live status for the public plane, read from `:persistent_term` (never a
  GenServer call — ticks run synchronously, so a call would block for the whole
  run). `suffix` selects the namespace; `lifecycle_ctx` surfaces the declared
  position. Times are unix seconds.
  """
  def status(suffix \\ "", lifecycle_ctx \\ nil) do
    base =
      :persistent_term.get(status_key(suffix), %{
        active: false,
        running: false,
        last_run: nil,
        next_run: nil,
        interval_ms: nil
      })

    Map.put(base, :lifecycle, lifecycle_ctx && Lifecycle.status(lifecycle_ctx))
  end

  defp status_key(""), do: {Workbooks.Keeper, :status}
  defp status_key(suffix), do: {Workbooks.Keeper, :status, suffix}

  defp put_status(cfg, patch) do
    :persistent_term.put(
      status_key(cfg.key_suffix),
      Map.merge(status(cfg.key_suffix, cfg.lifecycle_ctx), patch)
    )
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(%Cfg{} = cfg) do
    # Runs execute in a linked Task (see :tick) so they can be killed on
    # timeout; trap exits so a crashing run never takes the worker down.
    Process.flag(:trap_exit, true)

    case cfg.def_path do
      nil ->
        Logger.info("Keeper#{label(cfg)}: no def — idle")
        {:ok, %{cfg: cfg, active: false}}

      path ->
        # Catch-up scheduling: restarts must not reset the cadence clock. A crew
        # worker also gets a STAGGERED first delay (cfg.start_delay_ms) so agents
        # overlap visibly without thundering-herd onto the LLM at boot.
        delay = next_delay_ms(cfg) + cfg.start_delay_ms
        Logger.info("Keeper#{label(cfg)}: activated — def=#{path} interval=#{interval_ms(cfg)}ms first-tick-in=#{delay}ms")
        Process.send_after(self(), :tick, delay)

        put_status(cfg, %{
          active: true,
          running: false,
          agent: cfg.agent,
          interval_ms: interval_ms(cfg),
          last_run: read_last_run(cfg),
          next_run: System.system_time(:second) + div(delay, 1000)
        })

        {:ok, %{cfg: cfg, active: true, def_path: path, no_work_streak: 0}}
    end
  end

  @impl true
  def handle_info(:tick, %{active: false} = state), do: {:noreply, state}

  def handle_info(:tick, %{cfg: cfg, def_path: path} = state) do
    write_last_run(cfg)
    put_status(cfg, %{running: true, last_run: System.system_time(:second)})

    # When a lifecycle spec is active it decides what THIS tick is (wake vs rem,
    # and which wake state); otherwise we fall back to the env+prose path exactly
    # as before (zero regression when no lifecycle ctx). wb-2ku.3.
    outcome = run_tick(cfg, path, lifecycle_current(cfg))

    # IDLE BACKOFF (efficiency): a continuous worker that just returned NO-WORK
    # will almost certainly return NO-WORK again at the breather cadence (the
    # board state did not change) — re-running every ~10s burns an LLM call per
    # tick for nothing (the idle bit.ml crew). Count the NO-WORK streak and let
    # tick_delay_ms back off; ANY real work (:done) resets it to the hot cadence.
    streak = if outcome == :no_work, do: state.no_work_streak + 1, else: 0
    delay = tick_delay_ms(cfg, streak)

    Process.send_after(self(), :tick, delay)
    put_status(cfg, %{running: false, next_run: System.system_time(:second) + div(delay, 1000)})
    {:noreply, %{state | no_work_streak: streak}}
  end

  # trap_exit is on: absorb EXITs from run tasks (normal or killed).
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # ── tick dispatch ─────────────────────────────────────────────────────────────

  defp lifecycle_current(%Cfg{lifecycle_ctx: nil}), do: nil
  defp lifecycle_current(%Cfg{lifecycle_ctx: ctx}), do: Lifecycle.current(ctx)

  # No lifecycle spec → original behavior: run the def, then maybe-dream (the
  # time gate lives in Dreams). The agent def decides add-vs-audit from prose.
  defp run_tick(cfg, path, nil) do
    Logger.info("Keeper#{label(cfg)}: tick — running #{path}")
    outcome = wake(cfg, path, nil)
    # REM: after waking work, maybe dream (time-gated, fire-and-forget — a failed
    # or slow dream can never touch the run loop). wb-2ku.
    Task.start(fn -> Workbooks.Dreams.maybe_dream(System.get_env("WB_TENANT", "local")) end)
    outcome
  end

  # A gated state (rem before its min-interval elapsed, say) → no-op tick that
  # holds cadence position: advance(:done) is NOT called, so we re-evaluate the
  # same state next tick once the gate opens.
  defp run_tick(cfg, _path, %{gated: true, state: s}) do
    Logger.info("Keeper#{label(cfg)}: tick — #{s} gated (min-interval not elapsed), holding position")
  end

  # rem state: skip the agent run; dream directly (the time gate now lives in the
  # spec, not Dreams). A successful dream advances the lifecycle; a failed one
  # holds position (retry next tick).
  defp run_tick(cfg, _path, %{kind: :rem, state: s}) do
    Logger.info("Keeper#{label(cfg)}: tick — #{s} (rem) dreaming")
    Lifecycle.mark_ran(s, cfg.lifecycle_ctx)

    outcome =
      try do
        Workbooks.Dreams.dream(System.get_env("WB_TENANT", "local"))
        :done
      rescue
        e ->
          Logger.error("Keeper#{label(cfg)}: rem tick failed — #{Exception.message(e)}")
          :failed
      end

    Lifecycle.advance(outcome, cfg.lifecycle_ctx)
  end

  # wake state: run the def with the lifecycle state PREPENDED to the task line,
  # so the def no longer needs count-based prose to choose add vs audit.
  defp run_tick(cfg, path, %{kind: :wake, state: s}) do
    Logger.info("Keeper#{label(cfg)}: tick — #{s} (wake) running #{path}")
    Lifecycle.mark_ran(s, cfg.lifecycle_ctx)
    Lifecycle.advance(wake(cfg, path, s), cfg.lifecycle_ctx)
  end

  # Run the agent def under the wall-clock bound; returns the tick OUTCOME
  # (:done | :failed | :killed | :no_work) for the lifecycle to step on.
  # `lifecycle_state` (nil in the env+prose path) is prepended to the task line.
  #
  # The whole run is wrapped in the crew's global concurrency gate: acquire blocks
  # (queues) until a slot frees, release always runs (even on crash/timeout) so a
  # wedged worker can never starve the others.
  defp wake(cfg, path, lifecycle_state) do
    acquire(cfg)

    try do
      task = Task.async(fn -> run_def(cfg, File.read!(path), lifecycle_state) end)

      case Task.yield(task, run_timeout_ms(cfg)) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          out = result.result || ""
          Logger.info("Keeper#{label(cfg)}: tick done — #{inspect(String.slice(out, 0, 120))}")

          # wb-2ku.10: the agent signals "nothing my run-kind may do" by BEGINNING
          # its done result with NO-WORK. The lifecycle collapses this state's
          # remaining repeats instead of burning more slots on it.
          if String.match?(out, ~r/\A\s*NO-WORK\b/i), do: :no_work, else: :done

        {:exit, reason} ->
          Logger.error("Keeper#{label(cfg)}: tick failed — #{inspect(reason)}")
          :failed

        nil ->
          Logger.error("Keeper#{label(cfg)}: tick killed — exceeded #{run_timeout_ms(cfg)}ms wall clock")
          :killed
      end
    after
      release(cfg)
    end
  end

  defp acquire(%Cfg{acquire: f}) when is_function(f, 0), do: f.()
  defp acquire(_), do: :ok

  defp release(%Cfg{release: f}) when is_function(f, 0), do: f.()
  defp release(_), do: :ok

  # ── cadence persistence (survives restarts/redeploys) ───────────────────────

  defp last_run_path(cfg),
    do: Path.join(System.get_env("WB_DATA") || File.cwd!(), "keeper-last-run#{cfg.key_suffix}")

  defp write_last_run(cfg) do
    File.write(last_run_path(cfg), Integer.to_string(System.system_time(:second)))
  rescue
    _ -> :ok
  end

  defp read_last_run(cfg) do
    with {:ok, s} <- File.read(last_run_path(cfg)), {ts, _} <- Integer.parse(String.trim(s)), do: ts, else: (_ -> nil)
  end

  defp next_delay_ms(cfg) do
    case read_last_run(cfg) do
      nil ->
        @boot_grace_ms

      ts ->
        elapsed_ms = (System.system_time(:second) - ts) * 1000
        max(@boot_grace_ms, interval_ms(cfg) - elapsed_ms)
    end
  end

  # ── cadence knobs (per-worker; the singleton reads env, a crew worker is explicit) ──

  defp interval_ms(%Cfg{interval_ms: ms}) when is_integer(ms), do: ms
  defp interval_ms(_), do: @default_interval_ms

  defp run_timeout_ms(%Cfg{run_timeout_ms: ms}) when is_integer(ms), do: ms
  defp run_timeout_ms(_), do: @default_run_timeout_ms

  # NO-WORK idle backoff: with a streak of consecutive NO-WORK ticks, the next
  # tick waits max(base_cadence, 1min · 2^(streak-1)), capped at 30min — so an
  # idle worker quiets from ~10s polling to minutes between checks, while a single
  # :done (streak resets to 0) snaps it back to the hot base cadence. Applied in
  # BOTH modes: an interval worker idle for hours need not keep its hourly poll.
  @no_work_base_ms 60_000
  @no_work_cap_ms 1_800_000

  defp tick_delay_ms(cfg, 0), do: base_delay_ms(cfg)

  defp tick_delay_ms(cfg, streak) when streak > 0 do
    # cap the exponent before shifting so a long streak can't build a huge bignum
    backoff = min(@no_work_cap_ms, @no_work_base_ms * :erlang.bsl(1, min(streak - 1, 20)))
    max(base_delay_ms(cfg), backoff)
  end

  defp base_delay_ms(%Cfg{continuous: true} = cfg), do: cfg.breather_ms
  defp base_delay_ms(cfg), do: interval_ms(cfg)

  @doc false
  # test seam for the idle-backoff cadence (efficiency-critical — see tick_delay_ms/2)
  def tick_delay_for_test(%Cfg{} = cfg, streak), do: tick_delay_ms(cfg, streak)

  # ── the run itself ───────────────────────────────────────────────────────────

  # Run via AgentDef.run/3 — same path as /api/run. The agent gets a shell
  # (exec: true) and a workdir = the tenant's git repo, so its commits ARE the
  # public changelog. `cfg.agent` (the crew member's name) is threaded through as
  # :agent so every step + thought is tagged with this agent's identity.
  defp run_def(cfg, org, lifecycle_state) do
    mode = System.get_env("WB_KEEPER_MODE", "plan")
    tenant = System.get_env("WB_TENANT", "local")
    workdir = Workbooks.Git.repo_path(tenant)
    Workbooks.Git.ensure_repo(tenant)

    lifecycle_line = if lifecycle_state, do: "LIFECYCLE: #{lifecycle_state}\n", else: ""

    Workbooks.AgentDef.run(
      org,
      "MODE: #{mode}\n#{lifecycle_line}Perform one keeper run per your loop. Your working directory is this page's git repo.",
      exec: true,
      workdir: workdir,
      # Thread the tenant through: without it the agent defaults to tenant "dev",
      # so its commit→auto-publish wrote to build/public/DEV instead of the served
      # build/public/<tenant> dir — the lander committed 4 posts that 404'd because
      # they published to the wrong site root. Affects the crew identically.
      tenant: tenant,
      agent: cfg.agent,
      max_steps: 60
    )
  end

  # A short " (agent)" tag for log lines; empty for the singleton.
  defp label(%Cfg{agent: nil}), do: ""
  defp label(%Cfg{agent: a}), do: " (#{a})"
end
