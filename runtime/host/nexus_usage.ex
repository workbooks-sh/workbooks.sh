defmodule Workbooks.NexusUsage do
  @moduledoc """
  Real, Fly-grounded usage + cost rollup for an org's nexuses — the read model behind
  the dashboard's "Usage & billing" surface. Composes `Workbooks.NexusRegistry` (which
  nexuses the org owns), `Workbooks.FlyMachines` (the live machine + its event log) and
  `Workbooks.UsageMeter` (the append-only ledger).

  ## Where the numbers come from (no fabrication)
  Compute time is derived from the machine's OWN Fly event log: each running interval is
  a `start`/`launch` → `stop`/`exit` pair, summed to running-seconds. A machine that is
  scaled to zero (stopped) accrues `$0` for the idle time — that is the whole point of
  scale-to-zero, and the meter reflects it. Storage bytes come from the per-tenant
  storage usage (`Workbooks.Storage.usage_bytes/1`), already scoped to this org's prefix.

  ## Cost model
  Fly.io on-demand pricing for the default nexus guest (shared-cpu-1x). The rates are
  named constants derived from fly.io/docs/about/pricing — VERIFY before this drives a
  real invoice; they are intentionally easy to update in one place:

    * shared vCPU ≈ `@cpu_usd_per_month` per machine
    * RAM ≈ `@ram_usd_per_gb_month` per GB

  Cost only accrues while a machine is RUNNING; the per-second rate scales with the
  machine's actual guest size (cpus × cpu-rate + memory × ram-rate).

  ## Isolation
  Everything is scoped through `NexusRegistry.list(org_id)` — an org only ever sees the
  rollup for nexuses it owns. A blank org returns the empty rollup (fail-closed).

  ## Injectable for tests
  `opts[:fly]` / `opts[:registry]` / `opts[:usage]` / `opts[:now]` all default to the
  real collaborators; a test passes stubs to compute a rollup with no network and a
  pinned clock.
  """
  alias Workbooks.{NexusRegistry, UsageMeter}

  @seconds_per_month 2_592_000
  # Fly shared-cpu-1x compute + RAM, monthly (verify against fly.io pricing before billing).
  @cpu_usd_per_month 1.94
  @ram_usd_per_gb_month 5.0

  @doc """
  Build the usage + cost rollup for `org_id`. Returns

      %{
        summary: %{monthToDate, compute, storage, database, nexusCount, activeHrs},
        rows:    [%{name, plan, activeHrs, storage, database, cost}],
        period:  "<Month Year> · billed on the 1st"
      }

  A blank org → an all-zero rollup with no rows.
  """
  def rollup(org_id, opts \\ []) do
    if blank?(org_id) do
      empty(opts)
    else
      fly = Keyword.get(opts, :fly, Workbooks.FlyMachines)
      reg = Keyword.get(opts, :registry) || NexusRegistry.open()
      now = Keyword.get(opts, :now, System.system_time(:second))

      nexuses = NexusRegistry.list(org_id, reg)

      rows =
        Enum.map(nexuses, fn nx ->
          machine = fetch_machine(fly, nx, opts)
          secs = running_seconds(machine, now)
          rate = cost_per_second(machine)
          cost = secs * rate

          # Land the computed compute-seconds in the ledger so history accrues even
          # though the live truth is recomputed from Fly each read. Best-effort:
          # a ledger write failure must never break the dashboard read.
          _ = record_compute(org_id, nx[:id], secs, opts)

          %{
            name: nx[:id],
            plan: nx[:plan] || "starter",
            activeHrs: fmt_hrs(secs),
            storage: "—",
            database: if(nx[:neon_project_id] in [nil, ""], do: "—", else: "Postgres"),
            cost: fmt_usd(cost),
            _secs: secs,
            _cost: cost
          }
        end)

      compute_cost = Enum.reduce(rows, 0.0, fn r, a -> a + r._cost end)
      total_secs = Enum.reduce(rows, 0.0, fn r, a -> a + r._secs end)
      storage_bytes = storage_bytes(org_id)

      %{
        summary: %{
          monthToDate: fmt_usd(compute_cost),
          compute: fmt_usd(compute_cost),
          storage: fmt_gb(storage_bytes),
          database: "—",
          nexusCount: length(nexuses),
          activeHrs: fmt_hrs(total_secs)
        },
        rows: Enum.map(rows, &Map.drop(&1, [:_secs, :_cost])),
        period: "current cycle · billed on the 1st"
      }
    end
  end

  @doc """
  Running-seconds for a machine, summed from its Fly event log. Each `start`/`launch`
  opens an interval; the next `stop`/`exit` closes it. If the log ends mid-interval and
  the machine is currently `started`, the open interval accrues up to `now`. No events
  (or a never-started machine) → `0`.
  """
  def running_seconds(machine, now) when is_map(machine) do
    events =
      (machine["events"] || [])
      |> Enum.map(fn e -> {event_ts(e), e["type"]} end)
      |> Enum.reject(fn {ts, _} -> is_nil(ts) end)
      |> Enum.sort_by(&elem(&1, 0))

    {total, open} =
      Enum.reduce(events, {0, nil}, fn {ts, type}, {acc, open} ->
        cond do
          type in ["start", "launch"] -> {acc, open || ts}
          type in ["stop", "exit"] and open != nil -> {acc + (ts - open), nil}
          true -> {acc, open}
        end
      end)

    # Still running past the last event → accrue to now (clamp negatives to 0).
    tail = if open != nil and started?(machine), do: max(now - open, 0), else: 0
    max(total + tail, 0)
  end

  def running_seconds(_, _), do: 0

  @doc "Per-second USD cost for a machine's actual guest size (cpus + memory). 0 if unknown."
  def cost_per_second(machine) when is_map(machine) do
    guest = machine["config"]["guest"] || machine["guest"] || %{}
    cpus = numeric(guest["cpus"], 1)
    mem_mb = numeric(guest["memory_mb"], 1024)

    cpu = cpus * @cpu_usd_per_month / @seconds_per_month
    ram = mem_mb / 1024 * @ram_usd_per_gb_month / @seconds_per_month
    cpu + ram
  end

  def cost_per_second(_), do: 0.0

  # ── internals ─────────────────────────────────────────────────────────────────────

  defp fetch_machine(fly, nx, opts) do
    fly_opts = Keyword.take(opts, [:http, :token, :stub])

    case fly.get_machine(nx[:fly_app], nx[:fly_machine], fly_opts) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp record_compute(_org, _nexus, secs, _opts) when secs <= 0, do: :ok

  defp record_compute(org, nexus, secs, opts) do
    h = Keyword.get(opts, :usage)
    UsageMeter.record(org, nexus, "compute_seconds", secs * 1.0, h)
  rescue
    _ -> :ok
  end

  defp storage_bytes(org_id) do
    Workbooks.Storage.usage_bytes(org_id)
  rescue
    _ -> 0
  catch
    _, _ -> 0
  end

  defp started?(machine), do: (machine["state"] || machine["status"]) in ["started", "running"]

  # Fly events carry a millisecond `timestamp`; some shapes use `created_at` (ISO).
  defp event_ts(%{"timestamp" => ms}) when is_integer(ms), do: div(ms, 1000)
  defp event_ts(%{"timestamp" => ms}) when is_float(ms), do: trunc(ms / 1000)

  defp event_ts(%{"created_at" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt)
      _ -> nil
    end
  end

  defp event_ts(_), do: nil

  defp empty(opts) do
    %{
      summary: %{monthToDate: "$0.00", compute: "$0.00", storage: "0 GB", database: "—", nexusCount: 0, activeHrs: "0.0"},
      rows: [],
      period: Keyword.get(opts, :period, "current cycle · billed on the 1st")
    }
  end

  defp numeric(n, _d) when is_number(n) and n > 0, do: n
  defp numeric(_, d), do: d

  defp fmt_usd(n), do: "$" <> :erlang.float_to_binary(n * 1.0, decimals: 2)
  defp fmt_hrs(secs), do: :erlang.float_to_binary(secs / 3600, decimals: 1)

  defp fmt_gb(bytes) when is_number(bytes),
    do: :erlang.float_to_binary(bytes / 1_000_000_000, decimals: 2) <> " GB"

  defp fmt_gb(_), do: "0 GB"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
