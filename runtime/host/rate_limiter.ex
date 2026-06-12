defmodule Workbooks.RateLimiter do
  @moduledoc """
  wb-broker per-principal RATE QUOTA — a DoS floor for the brokers (many-requests / many-conns). `check/3`
  counts one request against a principal's fixed window and denies once it exceeds `max` within
  `window_ms`. The principal is the dock tenant (same identity used for revocation), so a runaway guest is
  throttled without affecting others.

  Lazy public ETS; the read-then-bump is approximate under heavy concurrency — fine for a floor (the point
  is to cap a runaway, not meter precisely). Uses monotonic time so it's immune to wall-clock jumps.
  """
  @table :wb_ratelimit

  # Per-tenant DoS FLOOR applied by every broker that doesn't get an explicit :rate. Generous on purpose —
  # the point is to stop a runaway guest (a tight loop spamming a broker does thousands/sec), NOT to meter
  # legitimate throughput. 2000 broker calls/sec per tenant. Override per-call with an explicit :rate.
  @default_quota {120_000, 60_000}

  @doc "The default per-tenant broker rate floor `{max, window_ms}` — used when no explicit :rate is given."
  def default_quota, do: @default_quota

  @doc "Count a request for `principal`. :ok if within budget, {:error, :rate_limited} once over `max`/window."
  def check(principal, max, window_ms) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table(), principal) do
      [{_, count, start}] when now - start < window_ms ->
        if count >= max do
          {:error, :rate_limited}
        else
          :ets.insert(table(), {principal, count + 1, start})
          :ok
        end

      _ ->
        # no record, or the prior window has elapsed → start a fresh window
        :ets.insert(table(), {principal, 1, now})
        :ok
    end
  end

  def reset(principal), do: :ets.delete(table(), principal) && :ok

  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, :set])
        rescue
          ArgumentError -> :ok
        end

        @table

      _ ->
        @table
    end
  end
end
