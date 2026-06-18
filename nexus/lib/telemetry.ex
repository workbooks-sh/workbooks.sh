defmodule Nexus.Telemetry do
  @moduledoc """
  §10 (execution reality) — the agent run ledger. When an agent runs, its real
  behaviour — turns, tokens, wall-clock, the kits it actually invoked, how it
  finished — is recorded here, keyed by the agent's canonical identity (§1,
  `WorkCore.Uid.key`). `overlay/0` projects the ledger into a `WorkCore.Overlay`
  that the pure graph joins at query time (`Graph.with_overlay/2`) to fill
  `facets.observed`. This is what lets *declared* (the grants + deps the author
  wrote) be checked against *observed* (what the agent did) under one identity.

  A GenServer holding `unit_key => [run]`. Recording is fire-and-forget; the agent
  loop is never blocked on it.
  """
  use GenServer

  alias WorkCore.{Uid, Overlay}

  # ── client ──

  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  # Lazily start outside a supervision tree (tests, escript) without racing.
  defp ensure do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _ ->
        :ok
    end
  end

  @doc "Record one agent run for `unit` (the literate unit name). Fire-and-forget."
  def record(nil, _run), do: :ok

  def record(unit, run) when is_map(run) do
    ensure()
    GenServer.cast(__MODULE__, {:record, Uid.key(unit), run})
  end

  @doc "Every recorded run for a unit (most recent first)."
  def runs(unit) do
    ensure()
    GenServer.call(__MODULE__, {:runs, Uid.key(unit)})
  end

  @doc "The aggregated observed facet for a unit, or nil if it never ran."
  def summary(unit) do
    case runs(unit) do
      [] -> nil
      rs -> aggregate(rs)
    end
  end

  @doc "Project the whole ledger into a reality overlay for `Graph.with_overlay/2`."
  def overlay do
    ensure()
    state = GenServer.call(__MODULE__, :all)

    Enum.reduce(state, Overlay.new(), fn {key, rs}, ov ->
      Overlay.put_observed(ov, key, aggregate(rs))
    end)
  end

  @doc "Wipe the ledger (test/maintenance)."
  def reset do
    ensure()
    GenServer.call(__MODULE__, :reset)
  end

  # ── aggregation ──

  defp aggregate(runs) do
    n = length(runs)

    %{
      runs: n,
      turns: sum(runs, & &1.turns),
      tokens: sum(runs, &get_in(&1, [:tokens, :total])),
      latency_ms: div(sum(runs, & &1.latency_ms), max(n, 1)),
      tools_used: runs |> Enum.flat_map(&Map.keys(&1.tools || %{})) |> Enum.uniq(),
      statuses: runs |> Enum.frequencies_by(& &1.status),
      errors: Enum.count(runs, &(&1.status == :error))
    }
  end

  defp sum(runs, fun), do: Enum.reduce(runs, 0, fn r, acc -> acc + (fun.(r) || 0) end)

  # ── server ──

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:record, key, run}, state),
    do: {:noreply, Map.update(state, key, [run], &[run | &1])}

  @impl true
  def handle_call({:runs, key}, _from, state), do: {:reply, Map.get(state, key, []), state}
  def handle_call(:all, _from, state), do: {:reply, state, state}
  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}
end
