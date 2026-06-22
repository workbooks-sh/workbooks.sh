defmodule Nexus.Analytics do
  @moduledoc """
  Built-in app analytics (Autopoiesis v2 — wb-a6u3.10). Distinct from `Nexus.Telemetry` (internal AGENT
  execution): this is real END-USER usage of an app or surface — page views, clicks, conversions, funnel
  steps. It is the sense that lets the autopoet reason about *app performance* ("this landing page isn't
  converting, change the hero"), not just agent health.

  Not a third-party product (no PostHog) — a built-in, tenant-scoped store fed off the event bus: a
  `client` island emits a usage `#event`, which `track/3` records. Queries — `counts/1`, `count/2`,
  `funnel/2`, `recent/2`, `summary/1` — are what a heartbeat reads. NO JSON: events are plain runtime
  state, never a config sidecar.
  """

  use GenServer

  @max_recent 500
  @default Nexus.Store.default_tenant()

  @doc false
  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

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

  @doc "Record a usage event `name` for `tenant` with optional `props`. Fire-and-forget."
  def track(name, tenant \\ @default, props \\ %{}) do
    ensure()
    GenServer.cast(__MODULE__, {:track, tenant, to_string(name), props, System.os_time(:second)})
  end

  @doc "Event-name → count for a tenant."
  def counts(tenant \\ @default) do
    ensure()
    GenServer.call(__MODULE__, {:counts, tenant})
  end

  @doc "Count of one event for a tenant."
  def count(name, tenant \\ @default), do: Map.get(counts(tenant), to_string(name), 0)

  @doc """
  A conversion funnel over ordered `steps` — each step's count and its conversion rate relative to the
  FIRST step. The autopoet's primary signal for "where users drop off". Rates are 0.0–1.0.
  """
  def funnel(steps, tenant \\ @default) when is_list(steps) do
    c = counts(tenant)
    first = Map.get(c, to_string(List.first(steps)), 0)

    for step <- steps do
      n = Map.get(c, to_string(step), 0)
      %{step: to_string(step), count: n, rate: if(first > 0, do: n / first, else: 0.0)}
    end
  end

  @doc "Most-recent events for a tenant (newest first), capped at `limit`."
  def recent(tenant \\ @default, limit \\ 50) do
    ensure()
    GenServer.call(__MODULE__, {:recent, tenant, limit})
  end

  @doc "A tenant's usage at a glance — total events, distinct names, per-name counts."
  def summary(tenant \\ @default) do
    c = counts(tenant)
    %{total: c |> Map.values() |> Enum.sum(), distinct: map_size(c), counts: c}
  end

  @doc "Wipe analytics (test/maintenance)."
  def reset do
    ensure()
    GenServer.call(__MODULE__, :reset)
  end

  # ── server ──

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_cast({:track, tenant, name, props, at}, state) do
    t = Map.get(state, tenant, %{counts: %{}, recent: []})

    t = %{
      counts: Map.update(t.counts, name, 1, &(&1 + 1)),
      recent: [%{name: name, props: props, at: at} | t.recent] |> Enum.take(@max_recent)
    }

    {:noreply, Map.put(state, tenant, t)}
  end

  @impl true
  def handle_call({:counts, tenant}, _from, state),
    do: {:reply, get_in(state, [tenant, :counts]) || %{}, state}

  def handle_call({:recent, tenant, limit}, _from, state),
    do: {:reply, (get_in(state, [tenant, :recent]) || []) |> Enum.take(limit), state}

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}
end
