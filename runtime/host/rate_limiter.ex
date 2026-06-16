defmodule Workbooks.RateLimiter do
  @moduledoc """
  wb-broker per-principal RATE QUOTA — a DoS floor for the brokers (many-requests / many-conns). `check/3`
  counts one request against a principal's fixed window and denies once it exceeds `max` within
  `window_ms`. The principal is the dock tenant (same identity used for revocation), so a runaway guest is
  throttled without affecting others.

  Lazy public ETS. wb-8w8x: the count is bumped ATOMICALLY via a time-bucketed `:ets.update_counter`, so
  concurrent broker calls on one principal can't lose updates and undercount (the old read-then-bump did).
  The bucket key `{principal, div(now, window)}` rolls each window — a fresh bucket auto-resets the count with
  no race. Uses monotonic time so it's immune to wall-clock jumps.
  """
  @table :wb_ratelimit

  # Per-tenant DoS FLOOR applied by every broker that doesn't get an explicit :rate. Generous on purpose —
  # the point is to stop a runaway guest (a tight loop spamming a broker does thousands/sec), NOT to meter
  # legitimate throughput. 2000 broker calls/sec per tenant. Override per-call with an explicit :rate.
  @default_quota {120_000, 60_000}

  @doc "The default per-tenant broker rate floor `{max, window_ms}` — used when no explicit :rate is given."
  def default_quota, do: @default_quota

  @doc "Count a request for `principal`. :ok if within budget, {:error, :rate_limited} once over `max`/window."
  def check(principal, max, window_ms) when window_ms > 0 do
    bucket = div(System.monotonic_time(:millisecond), window_ms)
    key = {principal, bucket}
    # ATOMIC increment (no read-then-bump race); a fresh bucket per window auto-resets the count.
    count = :ets.update_counter(table(), key, {2, 1}, {key, 0})
    # opportunistically drop the previous window's bucket so the table doesn't grow one entry per window
    :ets.delete(table(), {principal, bucket - 1})

    if count > max, do: {:error, :rate_limited}, else: :ok
  end

  def reset(principal) do
    # the key is {principal, bucket}, so delete every bucket for this principal
    :ets.match_delete(table(), {{principal, :_}, :_})
    :ok
  end

  # the table is owned by the long-lived Workbooks.BrokerTables process — NOT the (possibly transient) caller,
  # which would take the named table down with it when it dies (work self-audit: concurrent-task table loss).
  defp table, do: Workbooks.BrokerTables.ensure(@table, [:named_table, :public, :set])
end
