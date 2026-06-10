defmodule Workbooks.Keeper do
  @moduledoc """
  Runtime-native keeper scheduler (wb-5vm / lander-live).

  Runs an agent def on a timer, entirely on-box — needed when the control plane
  is internal-only and GitHub-cron can't reach it over a public URL.

  ## Singleton vs crew (wb-wc0.2)

  This module is now the SINGLETON FACADE. The actual tick engine lives in the
  instantiable `Workbooks.Keeper.Worker`; this module starts ONE worker with the
  legacy configuration (env-driven def, UNNAMESPACED persistence keys) and is
  registered under `Workbooks.Keeper` so the public plane + existing tests keep
  calling it exactly as before — zero regression for the lander. When a CREW
  manifest is declared (`WB_CREW_DEF`), `Workbooks.Keeper.Crew` instead starts one
  worker PER agent; see that module. The singleton and the crew never both run.

  ## Env contract (singleton)

    - `WB_KEEPER_DEF`         — path to an Org agent def file. **Required** to
                                activate the keeper; when unset the GenServer
                                starts but stays idle indefinitely.
    - `WB_KEEPER_INTERVAL_MS` — tick interval in ms (default: 3_600_000 = 1h).
                                First tick fires after one interval, not on boot.
    - `WB_KEEPER_MODE`        — `plan` (default) or `edit`. `plan` = the agent
                                only critiques + updates its backlog, never edits
                                the page. Passed into the task line; the def enforces it.
    - `WB_TENANT`             — the tenant whose git repo the keeper works in
                                (default "local"); the run's workdir is that repo,
                                so the keeper's commits ARE the public changelog.
    - `WB_LIFECYCLE_DEF`      — OPTIONAL path to a lifecycle state-machine spec
                                (see `Workbooks.Keeper.Lifecycle`). When set and
                                parseable, the keeper consults it for what each
                                tick IS; unset / unparseable → exactly the
                                env+prose behavior (zero regression).
    - `WB_KEEPER_CONTINUOUS`  — `1`/`true` → continuous mode (a short breather
                                between ticks instead of the full interval).

  `Workbooks.Keeper.run_once/0` triggers one tick immediately (watched manual run).

  ## Isolation

  Belongs entirely to the HOST layer: reads a loaded artifact (the .org def) but
  never calls into the PUBLIC plane, never touches the Dock membrane, and the run
  uses the same `AgentDef.run/3` path as `POST /api/brandnana-ask`. Crash-safe.
  """
  alias Workbooks.Keeper.Worker
  alias Workbooks.Keeper.Lifecycle

  # ── public API (singleton — delegates to one Worker registered under us) ─────

  @doc """
  Start the singleton keeper: ONE `Worker` registered under `Workbooks.Keeper`,
  configured from env with the LEGACY (unnamespaced) persistence keys. The pid is
  the worker — `send(pid, :tick)`, `GenServer.stop/1`, etc. all reach it, so the
  existing keeper_test path is unchanged.
  """
  def start_link(_opts \\ []) do
    Worker.start_link(singleton_cfg())
  end

  # The singleton config: legacy env knobs, empty key suffix (so files stay
  # `keeper-last-run` / `lifecycle-pos` and the status persistent_term key stays
  # `{Workbooks.Keeper, :status}`), no agent label, default lifecycle ctx (which
  # reads WB_LIFECYCLE_DEF and the unnamespaced position). This IS the seam that
  # keeps the lander's behavior byte-for-byte identical post-refactor.
  defp singleton_cfg do
    %Worker.Cfg{
      name: __MODULE__,
      agent: nil,
      def_path: System.get_env("WB_KEEPER_DEF"),
      lifecycle_ctx: Lifecycle.ctx(),
      key_suffix: "",
      interval_ms: env_int("WB_KEEPER_INTERVAL_MS"),
      run_timeout_ms: env_int("WB_KEEPER_RUN_TIMEOUT_MS"),
      continuous: System.get_env("WB_KEEPER_CONTINUOUS") in ["1", "true"],
      breather_ms: env_int("WB_KEEPER_BREATHER_MS") || 45_000,
      start_delay_ms: 0,
      acquire: nil,
      release: nil
    }
  end

  defp env_int(var) do
    case System.get_env(var) do
      nil -> nil
      s -> String.to_integer(s)
    end
  end

  @doc "Allow the supervisor to start this as a normal child."
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Trigger one keeper tick immediately (watched manual validation run)."
  def run_once, do: Worker.run_once(__MODULE__)

  @doc """
  Live keeper status for the public plane (read via `:persistent_term`, never a
  GenServer call). Returns the singleton namespace, with the declared lifecycle
  position folded in. Times are unix seconds.
  """
  def status, do: Worker.status("", Lifecycle.ctx())
end
