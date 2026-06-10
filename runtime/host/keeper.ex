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
    :persistent_term.get({__MODULE__, :status}, %{
      active: false,
      running: false,
      last_run: nil,
      next_run: nil,
      interval_ms: nil
    })
  end

  defp put_status(patch) do
    :persistent_term.put({__MODULE__, :status}, Map.merge(status(), patch))
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    case def_path() do
      nil ->
        Logger.info("Keeper: WB_KEEPER_DEF not set — idle")
        {:ok, %{active: false}}

      path ->
        Logger.info("Keeper: activated — def=#{path} interval=#{interval_ms()}ms")
        schedule()

        put_status(%{
          active: true,
          running: false,
          interval_ms: interval_ms(),
          next_run: System.system_time(:second) + div(interval_ms(), 1000)
        })

        {:ok, %{active: true, def_path: path}}
    end
  end

  @impl true
  def handle_info(:tick, %{active: false} = state), do: {:noreply, state}

  def handle_info(:tick, %{def_path: path} = state) do
    Logger.info("Keeper: tick — running #{path}")
    put_status(%{running: true, last_run: System.system_time(:second)})

    try do
      org = File.read!(path)
      result = run_def(org)
      Logger.info("Keeper: tick done — #{inspect(String.slice(result.result || "", 0, 120))}")
    rescue
      e ->
        Logger.error("Keeper: tick failed — #{Exception.message(e)}")
    end

    schedule()
    put_status(%{running: false, next_run: System.system_time(:second) + div(interval_ms(), 1000)})
    {:noreply, state}
  end

  # ── private helpers ──────────────────────────────────────────────────────────

  defp def_path, do: System.get_env("WB_KEEPER_DEF")

  defp interval_ms do
    case System.get_env("WB_KEEPER_INTERVAL_MS") do
      nil -> @default_interval_ms
      s -> String.to_integer(s)
    end
  end

  defp schedule, do: Process.send_after(self(), :tick, interval_ms())

  # Run via AgentDef.run/3 — same path as /api/run. The def's :MODEL: property is
  # honoured by AgentDef.run. The agent gets a shell (exec: true) and a workdir =
  # the tenant's git repo, so it reads/edits/commits the page IN its versioned
  # source of truth and its commits become the public changelog. The task line
  # carries the mode (plan|edit), which the def enforces.
  defp run_def(org) do
    mode = System.get_env("WB_KEEPER_MODE", "plan")
    tenant = System.get_env("WB_TENANT", "local")
    workdir = Workbooks.Git.repo_path(tenant)
    Workbooks.Git.ensure_repo(tenant)

    Workbooks.AgentDef.run(
      org,
      "MODE: #{mode}\nPerform one keeper run per your loop. Your working directory is this page's git repo.",
      exec: true,
      workdir: workdir,
      max_steps: 60
    )
  end
end
