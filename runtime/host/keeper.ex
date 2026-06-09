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
        {:ok, %{active: true, def_path: path}}
    end
  end

  @impl true
  def handle_info(:tick, %{active: false} = state), do: {:noreply, state}

  def handle_info(:tick, %{def_path: path} = state) do
    Logger.info("Keeper: tick — running #{path}")

    try do
      org = File.read!(path)
      result = run_def(org)
      Logger.info("Keeper: tick done — #{inspect(String.slice(result.result || "", 0, 120))}")
    rescue
      e ->
        Logger.error("Keeper: tick failed — #{Exception.message(e)}")
    end

    schedule()
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

  # Run via AgentDef.run/3 — same path as /api/brandnana-ask. The def's :MODEL:
  # property is honoured by AgentDef.run (it calls Agent.run with Keyword.put_new
  # :model). We pass sensible defaults and keep max_steps bounded.
  defp run_def(org) do
    Workbooks.AgentDef.run(
      org,
      "Perform one keeper run per your toolkit/skills.",
      max_steps: 60
    )
  end
end
