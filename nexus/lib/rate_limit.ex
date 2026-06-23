defmodule Nexus.RateLimit do
  @moduledoc """
  A tiny per-tenant fixed-window rate limiter (wb-9g6s). Backs the cost/egress caps on the Dock's
  `complete` (LLM) and `fetch` caps so one tenant granted `llm`/`net` can't drain the org's API spend
  or hammer egress within its compute budget.

  ETS-backed, leak-free: one row per `{tenant, kind}` holding `{count, window}`; when the window rolls
  over the row is overwritten (no per-window key accumulation, no sweeper). Approximate under a race by
  at most one call — fine for a DoS bound. The table is created at boot (`Nexus.Application`).
  """
  @table :nexus_ratelimit

  @doc "Create the backing table (idempotent) — called once from the application supervisor boot."
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Is one more `kind` action allowed for `tenant` right now? Permits up to `limit` actions per
  `window_secs` (default 60s). `limit <= 0` means unlimited (the cap is disabled). Fails OPEN if the
  table isn't up yet (never blocks legitimate work on a boot race).
  """
  def allow?(tenant, kind, limit, window_secs \\ 60)

  def allow?(_tenant, _kind, limit, _window) when not is_integer(limit) or limit <= 0, do: true

  def allow?(tenant, kind, limit, window_secs) do
    win = div(System.os_time(:second), window_secs)
    key = {tenant, kind}

    case :ets.lookup(@table, key) do
      [{^key, _count, ^win}] ->
        :ets.update_counter(@table, key, {2, 1}) <= limit

      _ ->
        # new tenant/kind OR the window rolled over → reset the row to a fresh window.
        :ets.insert(@table, {key, 1, win})
        limit >= 1
    end
  rescue
    ArgumentError -> true
  end
end
