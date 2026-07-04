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
          :ok = Sqlite3.bind(stmt, [tenant, Nexus.Store.Codec.encode(row)])
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
      Nexus.Store.Codec.decode_rows(rows, store: :sqlite, op: :all, resource: resource)
    end)
  end

  @doc """
  Data-explorer: the resource tables (`r_*`) that hold rows for `tenant`, each with its row count. Every
  resource is one table `(id, tenant, data)`, tenant-partitioned, so an org only ever sees its own rows.
  """
  def tables(tenant) do
    with_conn(fn conn ->
      {:ok, stmt} =
        Sqlite3.prepare(conn, "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'r\\_%' ESCAPE '\\' ORDER BY name")

      {:ok, names} = Sqlite3.fetch_all(conn, stmt)

      names
      |> Enum.map(fn [t] -> t end)
      |> Enum.map(fn t ->
        {:ok, cstmt} = Sqlite3.prepare(conn, "SELECT COUNT(*) FROM #{t} WHERE tenant = ?1")
        :ok = Sqlite3.bind(cstmt, [tenant])
        {:ok, [[count]]} = Sqlite3.fetch_all(conn, cstmt)
        %{name: String.replace_prefix(t, "r_", ""), table: t, rows: count}
      end)
      |> Enum.filter(&(&1.rows > 0))
    end)
  end

  @doc "Data-explorer: decoded rows of resource table `name` for `tenant` (newest first, capped at `limit`)."
  def rows(name, tenant, limit \\ 100) do
    t = if String.starts_with?(name, "r_"), do: name, else: "r_" <> name

    if Regex.match?(~r/\A[a-z0-9_]+\z/, t) do
      with_conn(fn conn ->
        {:ok, stmt} = Sqlite3.prepare(conn, "SELECT data FROM #{t} WHERE tenant = ?1 ORDER BY id DESC LIMIT ?2")
        :ok = Sqlite3.bind(stmt, [tenant, limit])
        {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
        Nexus.Store.Codec.decode_rows(rows, store: :sqlite, op: :all)
      end)
    else
      []
    end
  end

  @impl true
  def count(resource, tenant) do
    with_conn(fn conn ->
      ensure_table(conn, resource)
      count_sql(conn, resource, tenant)
    end)
  end

  # Native pagination. Default browse (no filter) pages at the DB on the `(tenant, id)` index — an
  # O(page) index seek, so a 100k-row table never loads into memory. Three native shapes:
  #   * `LIMIT/OFFSET` insertion-order (asc/desc) — classic browse.
  #   * KEYSET (`:before`/`:after` id cursor) — O(limit) regardless of scroll depth, the long-chat
  #     scroll-back case (`OFFSET` degrades as you page deeper; a cursor does not).
  # A `:q` filter or a field-sort can't be expressed over the opaque term blob, so those fall back
  # to the shared in-memory slicer (correct, not yet index-accelerated — column-mapping is wb-4d2e).
  @impl true
  def page(resource, tenant, opts) do
    o = Nexus.Store.Page.opts(opts)

    if Nexus.Store.Page.native_ok?(o) do
      with_conn(fn conn ->
        ensure_table(conn, resource)
        total = count_sql(conn, resource, tenant)
        {sql, binds} = page_sql(resource, tenant, o)
        {:ok, stmt} = Sqlite3.prepare(conn, sql)
        :ok = Sqlite3.bind(stmt, binds)
        {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
        {Nexus.Store.Codec.decode_rows(rows, store: :sqlite, op: :page, resource: resource), total}
      end)
    else
      Nexus.Store.Page.apply(all(resource, tenant), opts)
    end
  end

  # Assemble the native page query. Keyset (`:before`/`:after`) replaces OFFSET with an `id`
  # comparison on the indexed column — the scroll-back stays O(limit) however deep it goes.
  defp page_sql(resource, tenant, o) do
    dir = if o.order == :desc, do: "DESC", else: "ASC"
    base = "SELECT data FROM #{tbl(resource)} WHERE tenant = ?1"

    cond do
      o.before ->
        {base <> " AND id < ?2 ORDER BY id #{dir} LIMIT ?3", [tenant, o.before, o.limit]}

      o.after ->
        {base <> " AND id > ?2 ORDER BY id #{dir} LIMIT ?3", [tenant, o.after, o.limit]}

      true ->
        {base <> " ORDER BY id #{dir} LIMIT ?2 OFFSET ?3", [tenant, o.limit, o.offset]}
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
    t = tbl(resource)
    Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS #{t} (id INTEGER PRIMARY KEY, tenant TEXT, data BLOB)")
    # Every read is `WHERE tenant = ?` (often `ORDER BY id` / `id <cmp> cursor`). Without this the
    # query is a full table scan; the composite `(tenant, id)` index turns it into a covering seek —
    # the single biggest cold-load win on a multi-tenant table. IF NOT EXISTS = cheap on every call.
    Sqlite3.execute(conn, "CREATE INDEX IF NOT EXISTS #{t}_tenant_id ON #{t} (tenant, id)")
  end

  # Table name is derived from the resource MODULE name (server-defined, not attacker input today). It is
  # string-interpolated into SQL, so guard the identifier against `[a-z0-9_]+` as defense-in-depth: if a
  # resource module name ever becomes attacker-influenceable (dynamic compile of guest `.work`), an
  # injection attempt raises instead of reaching the query (red-team wb-iqyc).
  defp tbl(resource) do
    name = "r_" <> (resource |> Module.split() |> Enum.join("_") |> String.downcase())
    unless Regex.match?(~r/\A[a-z0-9_]+\z/, name), do: raise(ArgumentError, "unsafe table identifier: #{inspect(name)}")
    name
  end

  # Default to the durable volume DB under .nexus/ (Litestream replicates this). An explicit
  # `:sqlite_path` (dev per-workbook DB, tests) still wins.
  defp db_path, do: Application.get_env(:nexus, :sqlite_path) || Nexus.Paths.db_path()
end
