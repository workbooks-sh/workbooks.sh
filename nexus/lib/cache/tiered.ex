defmodule Nexus.Cache.Tiered do
  @moduledoc """
  Default `Nexus.Cache` provider — a supervised GenServer owning the **hot** ETS table, backed by the
  **cold** `Nexus.Cache.Cold` tier. Follows the `Nexus.Wasm.Gate` pattern: one supervised process,
  config-driven limit (`cache-hot-max-mb`), started via `Nexus.Cache.child_specs/0` in the app tree.

  ## Hot tier — bounded ETS, byte-budget LRU

  One ETS row per entry, keyed by `{tenant, namespace, key}`:

      {ck, value, expires_at, last_access, bytes}

  `bytes` = byte_size(value). We bound by **total bytes** (not entry count) because the real risk on
  the 1GB host is total RAM, and entries vary wildly in size; a byte budget tracks the actual memory
  wall. On `put`, if the new total exceeds the budget we evict the least-recently-used rows until it
  fits — and a still-live evicted row is **demoted to cold** first (write-through-on-evict). Reads
  bump `last_access`, so the LRU victim is genuinely the coldest entry.

  ## Cold tier — demote / promote

  On a hot miss we ask `Nexus.Cache.Cold` (Local by default, R2 on the cloud route; in tests, Local
  pointed at a tmp dir). A present,
  unexpired cold entry is **promoted** back into hot and returned; an expired one is a `:miss` (lazy
  expiry). Expiry is checked on read in both tiers, so a stale value is never served.

  All operations are serialized through the owner process: ETS LRU accounting + cold demote must be
  atomic w.r.t. each other, and cache traffic is light relative to the wasm lanes it accelerates.
  """
  @behaviour Nexus.Cache
  use GenServer

  alias Nexus.Cache.Cold

  @table :nexus_cache_hot

  # ── child / start ────────────────────────────────────────────────────────────────────────────
  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # ── Nexus.Cache callbacks ──────────────────────────────────────────────────────────────────────
  @impl Nexus.Cache
  def get(tenant, ns, key), do: GenServer.call(server(), {:get, tenant, ns, key})

  @impl Nexus.Cache
  def put(tenant, ns, key, value, opts) when is_binary(value),
    do: GenServer.call(server(), {:put, tenant, ns, key, value, opts})

  @impl Nexus.Cache
  def delete(tenant, ns, key), do: GenServer.call(server(), {:delete, tenant, ns, key})

  @doc "`%{bytes, max_bytes, entries}` — hot-tier observability."
  def stats, do: GenServer.call(server(), :stats)

  # In tests/tools the process may not be supervised; start a transient one on demand.
  defp server do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link([]) do
          {:ok, _} -> __MODULE__
          {:error, {:already_started, _}} -> __MODULE__
        end

      _ ->
        __MODULE__
    end
  end

  # ── server ───────────────────────────────────────────────────────────────────────────────────
  @impl GenServer
  def init(_opts) do
    table =
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
        tid -> tid
      end

    {:ok, %{table: table, bytes: total_bytes(table), max_bytes: max_bytes()}}
  end

  @impl GenServer
  def handle_call({:get, tenant, ns, key}, _from, s) do
    ck = {tenant, ns, key}

    case :ets.lookup(s.table, ck) do
      [{^ck, value, expires_at, _la, _b}] ->
        if expired?(expires_at) do
          {:reply, :miss, drop(s, ck)}
        else
          touch(s.table, ck)
          {:reply, {:ok, value}, s}
        end

      [] ->
        # hot miss → consult cold; promote a live entry.
        case Cold.get(tenant, ns, key) do
          {:ok, {value, expires_at}} ->
            if expired?(expires_at) do
              {:reply, :miss, s}
            else
              {:reply, {:ok, value}, store(s, ck, value, expires_at)}
            end

          :miss ->
            {:reply, :miss, s}
        end
    end
  end

  @impl GenServer
  def handle_call({:put, tenant, ns, key, value, opts}, _from, s) do
    expires_at = expires_at(opts)
    {:reply, :ok, store(s, {tenant, ns, key}, value, expires_at)}
  end

  @impl GenServer
  def handle_call({:delete, tenant, ns, key}, _from, s) do
    ck = {tenant, ns, key}
    Cold.delete(tenant, ns, key)
    {:reply, :ok, drop(s, ck)}
  end

  @impl GenServer
  def handle_call(:stats, _from, s) do
    {:reply, %{bytes: s.bytes, max_bytes: s.max_bytes, entries: :ets.info(s.table, :size)}, s}
  end

  # ── hot-tier mechanics ─────────────────────────────────────────────────────────────────────────
  defp store(s, ck, value, expires_at) do
    bytes = byte_size(value)
    now = mono()
    s = drop(s, ck)
    :ets.insert(s.table, {ck, value, expires_at, now, bytes})
    %{s | bytes: s.bytes + bytes} |> evict_to_fit()
  end

  defp drop(s, ck) do
    case :ets.lookup(s.table, ck) do
      [{^ck, _v, _e, _la, b}] ->
        :ets.delete(s.table, ck)
        %{s | bytes: s.bytes - b}

      [] ->
        s
    end
  end

  # bump last-access so LRU sees this row as hot.
  defp touch(table, ck), do: :ets.update_element(table, ck, {4, mono()})

  # Evict LRU rows until total bytes fit the budget; demote each still-live victim to cold first.
  defp evict_to_fit(%{bytes: bytes, max_bytes: max} = s) when bytes <= max, do: s

  defp evict_to_fit(s) do
    case lru_victim(s.table) do
      nil ->
        s

      {ck, value, expires_at, _la, _b} ->
        {tenant, ns, key} = ck
        unless expired?(expires_at), do: Cold.put(tenant, ns, key, {value, expires_at})
        s |> drop(ck) |> evict_to_fit()
    end
  end

  # the row with the smallest last_access (field 4). One table scan; cache traffic is light.
  defp lru_victim(table) do
    :ets.foldl(
      fn {_ck, _v, _e, la, _b} = row, acc ->
        case acc do
          nil -> row
          {_, _, _, ala, _} when la < ala -> row
          _ -> acc
        end
      end,
      nil,
      table
    )
  end

  defp total_bytes(table) do
    :ets.foldl(fn {_ck, _v, _e, _la, b}, acc -> acc + b end, 0, table)
  end

  # ── time / ttl ─────────────────────────────────────────────────────────────────────────────────
  defp expires_at(opts) do
    case Keyword.get(opts, :ttl, Nexus.Config.cache_default_ttl()) do
      :infinity -> :infinity
      ttl when is_integer(ttl) and ttl > 0 -> System.os_time(:second) + ttl
      _ -> :infinity
    end
  end

  defp expired?(:infinity), do: false
  defp expired?(at) when is_integer(at), do: System.os_time(:second) >= at

  defp mono, do: System.monotonic_time()
  defp max_bytes, do: Nexus.Config.cache_hot_max_mb() * 1024 * 1024
end
