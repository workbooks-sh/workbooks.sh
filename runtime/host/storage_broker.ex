defmodule Workbooks.StorageBroker do
  @moduledoc """
  wb-broker DURABLE STORAGE (Stone 3) — a host-brokered, PERSISTENT key/value store for guests. The
  in-instance VFS (host_vfs_*) is ephemeral (dies with the instance); this survives across runs, backed by
  a host sqlite file. The host owns the DB; the guest only ever names a key.

  Security cadence (mirrors the net/exec brokers):
    * TENANT ISOLATION — every row is scoped by `tenant`; a guest can only ever see its own namespace, so
      one tenant CANNOT read or overwrite another's keys (the core security property; tested adversarially).
    * QUOTAS — per-value size cap + per-tenant key-count cap (DoS / unbounded-growth defense).
    * BINARY-SAFE — values are BLOBs (arbitrary bytes survive).
  Conn-passing style (like Workbooks.VFS) so it's trivially testable; the Dock holds one app-supervised conn.
  """
  alias Exqlite.Sqlite3

  @max_value 1024 * 1024
  @max_keys 10_000

  @doc "Open (and migrate) the durable store at `path`. `:memory:` for tests that don't need persistence."
  def open(path) do
    {:ok, conn} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS wb_kv (
        tenant TEXT NOT NULL,
        key TEXT NOT NULL,
        value BLOB,
        updated_at INTEGER,
        PRIMARY KEY (tenant, key)
      )
      """)

    {:ok, conn}
  end

  @doc "Store `value` under (`tenant`, `key`). opts: `:max_value`, `:max_keys`. Returns :ok | {:error, _}."
  def put(conn, tenant, key, value, opts \\ [])
      when is_binary(tenant) and is_binary(key) and is_binary(value) do
    max_value = Keyword.get(opts, :max_value, @max_value)
    max_keys = Keyword.get(opts, :max_keys, @max_keys)

    cond do
      Workbooks.Revocation.revoked?(tenant) -> {:error, :revoked}
      key == "" or tenant == "" -> {:error, :invalid_key}
      byte_size(value) > max_value -> {:error, :value_too_large}
      not exists?(conn, tenant, key) and count(conn, tenant) >= max_keys -> {:error, :quota_exceeded}
      true -> do_put(conn, tenant, key, value)
    end
  end

  @doc "Fetch the value for (`tenant`, `key`). {:ok, value} | {:error, :not_found}."
  def get(conn, tenant, key) when is_binary(tenant) and is_binary(key) do
    if Workbooks.Revocation.revoked?(tenant) do
      {:error, :revoked}
    else
      do_get(conn, tenant, key)
    end
  end

  defp do_get(conn, tenant, key) do
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT value FROM wb_kv WHERE tenant = ?1 AND key = ?2")
    :ok = Sqlite3.bind(stmt, [tenant, key])

    res =
      case Sqlite3.step(conn, stmt) do
        {:row, [value]} -> {:ok, value}
        :done -> {:error, :not_found}
      end

    Sqlite3.release(conn, stmt)
    res
  end

  @doc "Delete (`tenant`, `key`). Always :ok (idempotent)."
  def delete(conn, tenant, key) when is_binary(tenant) and is_binary(key) do
    {:ok, stmt} = Sqlite3.prepare(conn, "DELETE FROM wb_kv WHERE tenant = ?1 AND key = ?2")
    :ok = Sqlite3.bind(stmt, [tenant, key])
    :done = Sqlite3.step(conn, stmt)
    Sqlite3.release(conn, stmt)
    :ok
  end

  @doc "List keys for `tenant` (optionally by `prefix`), scoped to that tenant only."
  def keys(conn, tenant, prefix \\ "") when is_binary(tenant) and is_binary(prefix) do
    {:ok, stmt} =
      Sqlite3.prepare(conn, "SELECT key FROM wb_kv WHERE tenant = ?1 AND key LIKE ?2 ORDER BY key")

    :ok = Sqlite3.bind(stmt, [tenant, prefix <> "%"])
    rows = collect(conn, stmt, [])
    Sqlite3.release(conn, stmt)
    rows
  end

  defp do_put(conn, tenant, key, value) do
    {:ok, stmt} =
      Sqlite3.prepare(
        conn,
        "INSERT OR REPLACE INTO wb_kv (tenant, key, value, updated_at) VALUES (?1, ?2, ?3, ?4)"
      )

    :ok = Sqlite3.bind(stmt, [tenant, key, value, System.system_time(:second)])
    :done = Sqlite3.step(conn, stmt)
    Sqlite3.release(conn, stmt)
    :ok
  end

  defp exists?(conn, tenant, key) do
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT 1 FROM wb_kv WHERE tenant = ?1 AND key = ?2")
    :ok = Sqlite3.bind(stmt, [tenant, key])
    found = match?({:row, _}, Sqlite3.step(conn, stmt))
    Sqlite3.release(conn, stmt)
    found
  end

  defp count(conn, tenant) do
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT COUNT(*) FROM wb_kv WHERE tenant = ?1")
    :ok = Sqlite3.bind(stmt, [tenant])
    {:row, [n]} = Sqlite3.step(conn, stmt)
    Sqlite3.release(conn, stmt)
    n
  end

  defp collect(conn, stmt, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, [k]} -> collect(conn, stmt, [k | acc])
      :done -> Enum.reverse(acc)
    end
  end
end

defmodule Workbooks.StorageBroker.Server do
  @moduledoc """
  App-wide durable k/v connection, lazily opened and SERIALIZING access (sqlite is single-writer). The Dock
  imports go through this so one persistent connection backs all guests; the durable file is `WB_KV_DB`
  (default a stable path). The TENANT is supplied by the Dock/host — never by the guest — so a guest can
  only touch its own namespace (the isolation boundary lives in the host, not the guest's arguments).
  """
  use Agent
  alias Workbooks.StorageBroker

  def start_link(opts \\ []) do
    path = Keyword.get(opts, :path, db_path())
    Agent.start_link(fn -> elem(StorageBroker.open(path), 1) end, name: __MODULE__)
  end

  defp db_path, do: System.get_env("WB_KV_DB", Path.join(System.tmp_dir!(), "wb_kv.db"))

  defp conn do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link() do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        Process.whereis(__MODULE__)

      pid ->
        pid
    end
  end

  def put(tenant, key, value, opts \\ []),
    do: Agent.get(conn(), &StorageBroker.put(&1, tenant, key, value, opts), 15_000)

  def get(tenant, key), do: Agent.get(conn(), &StorageBroker.get(&1, tenant, key), 15_000)
  def delete(tenant, key), do: Agent.get(conn(), &StorageBroker.delete(&1, tenant, key), 15_000)
end
