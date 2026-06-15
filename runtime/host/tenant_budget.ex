defmodule Workbooks.TenantBudget do
  @moduledoc """
  PER-TENANT AGGREGATE BUDGET (cloud-enable gap #4/#5). The brokers already cap CONCURRENCY (ExecBroker's
  per-principal slot count) and REQUEST-RATE (RateLimiter's per-principal window). Neither bounds the TOTAL
  cost a tenant can run up over a window — a tenant can sustain max concurrency + max request-rate (and
  unbounded LLM spend) indefinitely, starving the host wallet and fairness. This module is the missing
  aggregate ceiling: a rolling-window COST budget keyed by the SAME principal/tenant the broker rate-limits
  and revokes on, so it composes with (does not replace) those caps.

  TWO metered dimensions, one window:
    * `:exec`  — brokered exec "cost units" (one unit per brokered exec call by default; a heavier op may
                 charge more). Bounds total brokered work per tenant per window beyond instantaneous rate.
    * `:llm`   — LLM tokens spent (prompt+completion). The agent path parses usage; charge it here so a
                 tenant's real LLM spend has a per-window ceiling, not just a per-request rate.

  Fail-CLOSED: `charge/3` denies (`{:error, :budget_exceeded}`) once the window total would exceed the cap,
  and a denied charge is NOT recorded (no partial debit). Multi-tenant ONLY: in single-tenant/desktop the
  budget is unlimited (returns :ok) so the desktop posture is unchanged. Caps are env-tunable for the hosted
  deployment; the defaults are deliberately generous-but-finite.

  Storage: a public ETS set owned by the long-lived `Workbooks.BrokerTables` (same durability rationale as
  RateLimiter — a transient creator must not take the table down). Atomic via time-bucketed
  `:ets.update_counter`, mirroring RateLimiter so concurrent charges can't undercount.
  """

  @table :wb_tenant_budget

  # window for the aggregate budget (ms). One minute by default.
  @window_ms 60_000

  # default per-tenant ceilings PER WINDOW (hosted posture). Generous enough for legitimate fan-out + a real
  # agent turn, finite enough that one tenant can't run the host's wallet/CPU unbounded.
  #   exec: ~brokered exec calls/min (vs RateLimiter's 120k req/min instantaneous floor — this aggregate is
  #         the SUSTAINED ceiling, intentionally far below the instantaneous burst rate).
  @default_exec_budget 10_000
  #   llm: tokens/min per tenant.
  @default_llm_budget 2_000_000

  @doc "The budget window in ms."
  def window_ms, do: @window_ms

  @doc "Per-tenant exec-cost ceiling per window (env `WB_TENANT_EXEC_BUDGET`)."
  def exec_budget, do: env_int("WB_TENANT_EXEC_BUDGET", @default_exec_budget)

  @doc "Per-tenant LLM-token ceiling per window (env `WB_TENANT_LLM_BUDGET`)."
  def llm_budget, do: env_int("WB_TENANT_LLM_BUDGET", @default_llm_budget)

  @doc """
  Charge `cost` units of `dimension` (`:exec` | `:llm`) to `principal`'s current window. Returns `:ok` when
  within budget (and records the debit) or `{:error, :budget_exceeded}` when the charge would breach the cap
  (NOT recorded). Single-tenant/desktop or a nil principal => unlimited (`:ok`, no metering). A non-positive
  cost is a no-op `:ok`.
  """
  def charge(principal, dimension, cost \\ 1)

  def charge(principal, dimension, cost)
      when is_binary(principal) and principal != "" and is_integer(cost) and cost > 0 and
             dimension in [:exec, :llm] do
    if Workbooks.Tenancy.multi?() do
      do_charge(principal, dimension, cost, cap(dimension))
    else
      :ok
    end
  end

  def charge(_principal, _dimension, _cost), do: :ok

  @doc "Current spend for `principal`/`dimension` in the active window (telemetry/test)."
  def spent(principal, dimension) when is_binary(principal) do
    key = bucket_key(principal, dimension)

    case :ets.lookup(table(), key) do
      [{^key, n}] -> n
      _ -> 0
    end
  end

  @doc "Reset a principal's budget across all dimensions/windows (test/admin)."
  def reset(principal) do
    :ets.match_delete(table(), {{principal, :_, :_}, :_})
    :ok
  end

  defp cap(:exec), do: exec_budget()
  defp cap(:llm), do: llm_budget()

  defp do_charge(principal, dimension, cost, cap) do
    key = bucket_key(principal, dimension)
    total = :ets.update_counter(table(), key, {2, cost}, {key, 0})
    # opportunistically drop the previous window's bucket so the table doesn't grow unbounded.
    :ets.delete(table(), prev_bucket_key(principal, dimension))

    if total > cap do
      # over budget: roll the debit back so a denied charge leaves the window total untouched, then deny.
      :ets.update_counter(table(), key, {2, -cost}, {key, 0})
      {:error, :budget_exceeded}
    else
      :ok
    end
  end

  defp bucket_key(principal, dimension),
    do: {principal, dimension, div(System.monotonic_time(:millisecond), @window_ms)}

  defp prev_bucket_key(principal, dimension),
    do: {principal, dimension, div(System.monotonic_time(:millisecond), @window_ms) - 1}

  defp env_int(var, default) do
    case System.get_env(var) do
      s when is_binary(s) and s != "" ->
        case Integer.parse(s) do
          {n, _} when n > 0 -> n
          _ -> default
        end

      _ ->
        default
    end
  end

  defp table, do: Workbooks.BrokerTables.ensure(@table, [:named_table, :public, :set])
end
