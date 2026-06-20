defmodule Nexus.ControlPlane.Store do
  @moduledoc """
  The durable owner of the control-plane registry — a **SQLite** table (`cp`) inside the nexus's
  durable DB (`Nexus.Litestream.db_path`), so it rides the same Litestream→object-store replication
  as everything else: the control plane survives redeploys / machine churn with **no Fly volume**
  (Litestream restores it on boot). Was DETS — moved to SQLite so durability is uniform and
  volume-free (breaking: DETS rows are not migrated; the registry rebuilds from live state).

  Records are keyed `{org, kind, id}` and stored as Erlang-term blobs (type-preserving, no JSON
  sidecar). This GenServer just ensures the table exists at boot; reads/writes open their own
  connection (SQLite WAL serializes the single writer), mirroring `Nexus.Store.Sqlite`.
  """
  use GenServer
  alias Exqlite.Sqlite3

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    with_conn(fn conn ->
      Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS cp (org TEXT, kind TEXT, id TEXT, data BLOB, PRIMARY KEY(org,kind,id))")
    end)

    {:ok, %{}}
  end

  # ── KV API (replaces the raw :dets calls control_plane.ex / domain.ex used) ──────────────────────

  @doc "Insert or replace the record at `{org, kind, id}`."
  def put(org, kind, id, rec) do
    exec("INSERT OR REPLACE INTO cp(org,kind,id,data) VALUES(?1,?2,?3,?4)",
      [org, to_string(kind), id, :erlang.term_to_binary(rec)])
  end

  @doc "`{:ok, rec}` or `:error`."
  def get(org, kind, id) do
    case query("SELECT data FROM cp WHERE org=?1 AND kind=?2 AND id=?3", [org, to_string(kind), id]) do
      [rec] -> {:ok, rec}
      _ -> :error
    end
  end

  @doc "All records for an org of a kind."
  def list(org, kind), do: query("SELECT data FROM cp WHERE org=?1 AND kind=?2", [org, to_string(kind)])

  @doc "All records of a kind across every org (the one cross-org read — domain uniqueness)."
  def list_kind(kind), do: query("SELECT data FROM cp WHERE kind=?1", [to_string(kind)])

  @doc "Delete `{org, kind, id}`."
  def delete(org, kind, id), do: exec("DELETE FROM cp WHERE org=?1 AND kind=?2 AND id=?3", [org, to_string(kind), id])

  @doc "Wipe the whole registry (test/reset)."
  def delete_all, do: exec("DELETE FROM cp", [])

  # ── SQLite plumbing ──────────────────────────────────────────────────────────────────────────────

  defp db_path, do: Application.get_env(:nexus, :cp_sqlite_path) || Nexus.Litestream.db_path()

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

  defp exec(sql, binds) do
    with_conn(fn conn ->
      {:ok, stmt} = Sqlite3.prepare(conn, sql)
      :ok = Sqlite3.bind(stmt, binds)
      :done = Sqlite3.step(conn, stmt)
      Sqlite3.release(conn, stmt)
    end)

    :ok
  end

  defp query(sql, binds) do
    with_conn(fn conn ->
      {:ok, stmt} = Sqlite3.prepare(conn, sql)
      :ok = Sqlite3.bind(stmt, binds)
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      Enum.map(rows, fn [blob] -> :erlang.binary_to_term(blob) end)
    end)
  end
end
