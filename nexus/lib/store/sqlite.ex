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
  def count(resource, tenant) do
    with_conn(fn conn ->
      ensure_table(conn, resource)
      count_sql(conn, resource, tenant)
    end)
  end

  # Native pagination. Default browse (no filter, insertion-order sort) pages at the DB with
  # `LIMIT/OFFSET` + a `COUNT(*)` total — O(page), so a 100k-row table doesn't load into memory.
  # A `:q` filter or a field-sort can't be expressed over the opaque term blob, so those fall back
  # to the shared in-memory slicer (correct, not yet index-accelerated — column-mapping is wb-4d2e).
  @impl true
  def page(resource, tenant, opts) do
    o = Nexus.Store.Page.opts(opts)

    if Nexus.Store.Page.native_ok?(o) do
      with_conn(fn conn ->
        ensure_table(conn, resource)
        total = count_sql(conn, resource, tenant)

        {:ok, stmt} =
          Sqlite3.prepare(
            conn,
            "SELECT data FROM #{tbl(resource)} WHERE tenant = ?1 ORDER BY id LIMIT ?2 OFFSET ?3"
          )

        :ok = Sqlite3.bind(stmt, [tenant, o.limit, o.offset])
        {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
        {Enum.map(rows, fn [blob] -> :erlang.binary_to_term(blob) end), total}
      end)
    else
      Nexus.Store.Page.apply(all(resource, tenant), opts)
    end
  end

  defp count_sql(conn, resource, tenant) do
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT COUNT(*) FROM #{tbl(resource)} WHERE tenant = ?1")
    :ok = Sqlite3.bind(stmt, [tenant])
    {:ok, [[n]]} = Sqlite3.fetch_all(conn, stmt)
    n
  end

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
  defp db_path, do: Application.get_env(:nexus, :sqlite_path) || Nexus.Paths.db_path()
end
