defmodule Nexus.Auth.TokenStore do
  @moduledoc """
  Shared **SQLite** backing for the hashed-at-rest token tables (`Nexus.Auth.Token`,
  `Nexus.ControlPlane.Token`) — a `(hash PK, scope, id, data)` table inside the durable, Litestream-
  replicated `nexus.db`. Was per-store DETS; SQLite makes token durability uniform and **volume-free**
  (Litestream restores on boot), and the indexed `scope` column turns list/revoke from a full scan
  into a query. `scope` is the owning org (control plane) or tenant (auth); `data` is the full
  term-blob record (only the token's hash is ever stored, never the plaintext).
  """
  alias Exqlite.Sqlite3

  @tables %{cp_tokens: "cp_tokens", auth_tokens: "auth_tokens"}

  @doc "Create the table if absent (called at boot by the owning GenServer)."
  def ensure(table), do: run(table, "CREATE TABLE IF NOT EXISTS #{t(table)} (hash TEXT PRIMARY KEY, scope TEXT, id TEXT, data BLOB)", [])

  @doc "Insert or replace a token record by hash."
  def put(table, hash, scope, id, rec),
    do: run(table, "INSERT OR REPLACE INTO #{t(table)}(hash,scope,id,data) VALUES(?1,?2,?3,?4)", [hash, scope, id, Nexus.Store.Codec.encode(rec)])

  @doc "`{:ok, rec}` by hash, or `:error`."
  def get(table, hash) do
    case rows(table, "SELECT data FROM #{t(table)} WHERE hash=?1", [hash]) do
      [rec] -> {:ok, rec}
      _ -> :error
    end
  end

  @doc "All records owned by `scope` (an org or tenant)."
  def list_scope(table, scope), do: rows(table, "SELECT data FROM #{t(table)} WHERE scope=?1", [scope])

  @doc "Delete a scope's token by id. Idempotent."
  def revoke(table, scope, id), do: run(table, "DELETE FROM #{t(table)} WHERE scope=?1 AND id=?2", [scope, id])

  # ── plumbing ──
  defp t(table), do: Map.fetch!(@tables, table)
  defp db_path, do: Nexus.Paths.db_path()

  defp with_conn(fun) do
    path = db_path()
    File.mkdir_p!(Path.dirname(path))
    {:ok, conn} = Sqlite3.open(path)
    Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")

    try do
      fun.(conn)
    after
      Sqlite3.close(conn)
    end
  end

  defp run(_table, sql, binds) do
    with_conn(fn conn ->
      {:ok, stmt} = Sqlite3.prepare(conn, sql)
      :ok = Sqlite3.bind(stmt, binds)
      :done = Sqlite3.step(conn, stmt)
      Sqlite3.release(conn, stmt)
    end)

    :ok
  end

  defp rows(_table, sql, binds) do
    with_conn(fn conn ->
      {:ok, stmt} = Sqlite3.prepare(conn, sql)
      :ok = Sqlite3.bind(stmt, binds)
      {:ok, rs} = Sqlite3.fetch_all(conn, stmt)
      Nexus.Store.Codec.decode_rows(rs, store: :token_store)
    end)
  end
end
