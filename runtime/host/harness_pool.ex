defmodule Workbooks.HarnessPool do
  @moduledoc """
  PER-TENANT RESIDENT-INSTANCE POOL for `Workbooks.HarnessSession` (cloud-enable gap #1 — host OOM).

  THE GAP THIS CLOSES (audit): each live `HarnessSession` holds a ~10MB+ resident StarlingMonkey heap until
  its `@idle_ms` (5min) idle eviction. The session `Registry` is one FLAT global keyspace `keys: :unique`
  with NO cap on how many live sessions a single tenant may hold, so one tenant could open unbounded sessions
  (or churn under the 5-min idle window) and OOM the shared BEAM, starving every other tenant. The
  HarnessSession moduledoc itself flagged "a per-registry session cap upstream … not built here".

  THIS module is that cap. Every PRODUCTION session start goes through `start_session/2`, which:
    * NAMESPACES the session id by the VERIFIED tenant — `"<tenant>:<session>"` — so the flat Registry
      keyspace can never collide across tenants and a session id is structurally tenant-scoped.
    * BINDS the grant principal + creds_scope user to the SAME verified tenant (gap #2) — a caller cannot
      mint a grant charging another tenant's exec/rate/LLM budget or aimed at another tenant's keychain.
    * enforces `@max_sessions_per_tenant` — refuses (or LRU-evicts the tenant's oldest) past the cap, so one
      tenant cannot hold unbounded resident heaps.
    * enforces a GLOBAL `@max_resident_sessions` ceiling as a host backstop across ALL tenants.

  Tracking is in the long-lived `Workbooks.BrokerTables` ETS (durable for the app lifetime — a transient
  caller must not take it down). `@idle_ms` eviction in HarnessSession plus the session `terminate` releasing
  its pool slot keep the count honest; a dead pid is reaped lazily on the next start for the same tenant.
  """
  require Logger

  alias Workbooks.{HarnessSession, BrokerTables}

  @table :wb_harness_pool

  # resident sessions per tenant (env `WB_HARNESS_MAX_PER_TENANT`).
  @max_sessions_per_tenant 6
  # global resident-session ceiling across ALL tenants (env `WB_HARNESS_MAX_RESIDENT`) — host OOM backstop.
  @max_resident_sessions 256

  @doc "Per-tenant resident-session cap."
  def max_per_tenant, do: env_int("WB_HARNESS_MAX_PER_TENANT", @max_sessions_per_tenant)

  @doc "Global resident-session ceiling."
  def max_resident, do: env_int("WB_HARNESS_MAX_RESIDENT", @max_resident_sessions)

  @doc """
  Start (or look up) a tenant-bound harness session. `tenant` MUST be the AUTH-VERIFIED tenant (gap #2 — never
  a caller-supplied principal). `opts` mirror `HarnessSession.start_link/1` EXCEPT that this function:

    * derives the namespaced `:session_id` `"<tenant>:<session>"` from `opts[:session]` (a per-tenant-unique
      sub-id; default a random ref) — the caller cannot choose the global session id;
    * OVERRIDES the grant `:principal` (in `:exec`) and `creds_scope.user` to `tenant`, so the broker's
      rate/concurrency/budget/revocation key and the keychain scope are the verified tenant — a caller's
      principal/creds_scope are ignored, closing the cross-tenant principal/creds spoof;
    * enforces the per-tenant and global resident caps.

  Returns `{:ok, pid}` | `{:error, :tenant_session_cap}` | `{:error, :host_session_cap}` | the start error.
  Idempotent on a live id: an existing live session for the namespaced id is returned as-is.
  """
  def start_session(tenant, opts \\ []) when is_binary(tenant) and tenant != "" do
    sub = to_string(Keyword.get(opts, :session) || :erlang.ref_to_list(make_ref()))
    sid = namespaced_id(tenant, sub)

    case HarnessSession.whereis(sid) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: do_start(tenant, sid, opts)

      _ ->
        do_start(tenant, sid, opts)
    end
  end

  @doc "The namespaced (tenant-scoped) session id for a tenant + sub-id."
  def namespaced_id(tenant, sub) when is_binary(tenant) and is_binary(sub), do: tenant <> ":" <> sub

  @doc "Count of LIVE resident sessions held by `tenant` (reaps dead pids)."
  def count_for(tenant) when is_binary(tenant) do
    reap()
    :ets.select_count(table(), [{{:_, tenant, :_, :_}, [], [true]}])
  end

  @doc "Total LIVE resident sessions across all tenants (reaps dead pids)."
  def resident_total do
    reap()
    :ets.info(table(), :size) || 0
  end

  @doc """
  Release `tenant`'s pool slot for the namespaced `sid` (called from `HarnessSession.terminate`). Idempotent.
  """
  def release(sid) when is_binary(sid) do
    :ets.delete(table(), sid)
    :ok
  end

  # ── internals ──────────────────────────────────────────────────────────────────────────────────

  defp do_start(tenant, sid, opts) do
    reap()

    cond do
      resident_total() >= max_resident() ->
        Logger.warning("harness-pool: GLOBAL resident-session ceiling (#{max_resident()}) hit — refusing #{sid}")
        {:error, :host_session_cap}

      count_for(tenant) >= max_per_tenant() ->
        Logger.warning("harness-pool: tenant #{inspect(tenant)} at session cap (#{max_per_tenant()}) — refusing #{sid}")
        {:error, :tenant_session_cap}

      true ->
        bound = bind_to_tenant(tenant, sid, opts)

        case HarnessSession.start_link(bound) do
          {:ok, pid} ->
            :ets.insert(table(), {sid, tenant, pid, System.monotonic_time(:millisecond)})
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            :ets.insert(table(), {sid, tenant, pid, System.monotonic_time(:millisecond)})
            {:ok, pid}

          other ->
            other
        end
    end
  end

  # OVERRIDE the principal + creds_scope user with the VERIFIED tenant so a caller can never charge/scope to
  # another tenant (gap #2). The session_id is the namespaced id (caller can't choose the global key).
  defp bind_to_tenant(tenant, sid, opts) do
    opts
    |> Keyword.put(:session_id, sid)
    |> Keyword.delete(:session)
    |> update_in_keyword(:exec, fn exec ->
      exec = exec || []

      exec
      |> Keyword.put(:principal, tenant)
      |> then(fn e ->
        case Keyword.get(e, :creds_scope) do
          %{} = cs -> Keyword.put(e, :creds_scope, Map.put(cs, :user, tenant))
          _ -> e
        end
      end)
    end)
    |> update_in_keyword(:fs, fn
      nil -> nil
      fs -> Keyword.put(fs, :principal, tenant)
    end)
  end

  defp update_in_keyword(opts, key, fun) do
    case Keyword.has_key?(opts, key) do
      true -> Keyword.put(opts, key, fun.(Keyword.get(opts, key)))
      false ->
        case fun.(nil) do
          nil -> opts
          v -> Keyword.put(opts, key, v)
        end
    end
  end

  # reap dead pids so the cap counts only LIVE sessions (idle-evicted/crashed sessions also call release/1 via
  # terminate, but a brutal kill may skip it — this is the backstop).
  defp reap do
    :ets.foldl(
      fn {sid, _t, pid, _ts}, acc ->
        if is_pid(pid) and Process.alive?(pid), do: acc, else: [sid | acc]
      end,
      [],
      table()
    )
    |> Enum.each(&:ets.delete(table(), &1))
  rescue
    _ -> :ok
  end

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

  defp table, do: BrokerTables.ensure(@table, [:named_table, :public, :set])
end
