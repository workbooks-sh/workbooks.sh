defmodule Nexus.Store.Sqlite do
  @moduledoc """
  A durable `Nexus.Store` backend on SQLite (via `exqlite`) — the "survives a restart" option behind
  the universal seam. One table per resource: `(id, tenant, data)`, **partitioned by tenant** so
  isolation is enforced in storage. Rows are the serialized struct (enum atoms round-trip exactly).
  `config :nexus, store_adapter: Nexus.Store.Sqlite` (db path via `:sqlite_path`, default a temp file).

  NOTE: rows are a term blob — durable + correct, not yet field-queryable in SQL. Column-mapping is
  the enhancement; the same applies to a Postgres/wasm-SQL adapter behind these callbacks.
  """
  @behaviour Nexus.Store
  alias Exqlite.Sqlite3

  @impl true
  def create(resource, attrs, tenant) do
    case Nexus.Resource.validate(resource, attrs) do
      {:ok, row} ->
        with_conn(fn conn ->
          ensure_table(conn, resource)
          {:ok, stmt} = Sqlite3.prepare(conn, "INSERT INTO #{tbl(resource)} (tenant, data) VALUES (?1, ?2)")
          :ok = Sqlite3.bind(stmt, [tenant, :erlang.term_to_binary(row)])
          :done = Sqlite3.step(conn, stmt)
        end)

        {:ok, row}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def all(resource, tenant) do
    with_conn(fn conn ->
      ensure_table(conn, resource)
      {:ok, stmt} = Sqlite3.prepare(conn, "SELECT data FROM #{tbl(resource)} WHERE tenant = ?1 ORDER BY id")
      :ok = Sqlite3.bind(stmt, [tenant])
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      Enum.map(rows, fn [blob] -> :erlang.binary_to_term(blob) end)
    end)
  end

  @impl true
  def count(resource, tenant), do: length(all(resource, tenant))

  @impl true
  def clear(resource, tenant) do
    with_conn(fn conn ->
      ensure_table(conn, resource)
      {:ok, stmt} = Sqlite3.prepare(conn, "DELETE FROM #{tbl(resource)} WHERE tenant = ?1")
      :ok = Sqlite3.bind(stmt, [tenant])
      :done = Sqlite3.step(conn, stmt)
    end)

    :ok
  end

  defp with_conn(fun) do
    path = db_path()
    File.mkdir_p!(Path.dirname(path))
    {:ok, conn} = Sqlite3.open(path)
    # WAL is REQUIRED for Litestream (it ships WAL frames off-box) and lets reads run concurrently
    # with the single writer. busy_timeout absorbs brief lock contention instead of erroring.
    Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")

    try do
      fun.(conn)
    after
      Sqlite3.close(conn)
    end
  end

  defp ensure_table(conn, resource) do
    Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS #{tbl(resource)} (id INTEGER PRIMARY KEY, tenant TEXT, data BLOB)")
  end

  defp tbl(resource), do: "r_" <> (resource |> Module.split() |> Enum.join("_") |> String.downcase())

  # Default to the durable volume DB under .nexus/ (Litestream replicates this). An explicit
  # `:sqlite_path` (dev per-workbook DB, tests) still wins.
  defp db_path, do: Application.get_env(:nexus, :sqlite_path) || Nexus.Litestream.db_path()
end
