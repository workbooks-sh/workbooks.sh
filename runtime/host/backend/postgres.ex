defmodule Workbooks.Backend.Postgres do
  @moduledoc """
  BYOD Postgres backend (L2) — the cloud-cell swap for indexed/shared storage
  (tenant-wide search, presence, analytics). The deploy-time alternative to
  `Backend.SQLite`: a cell sets `config :workbooks, :backends, [{:analytics,
  Backend.Postgres, dsn: "..."}]` and core is unchanged.

  Real over `postgrex`: a collection is a `(id text primary key, doc jsonb)`
  table; `write` upserts, `read` filters by the doc's JSON fields, `query` runs
  raw SQL. Same JSON-doc shape as `Backend.SQLite`, so a workbook is portable
  between local and cloud cells. `init` opts: a `:dsn` or discrete
  hostname/port/username/password/database keys (Postgrex options).
  """
  @behaviour Workbooks.Backend

  @impl true
  def init(opts) do
    opts = if dsn = opts[:dsn], do: parse_dsn(dsn), else: opts
    Postgrex.start_link(opts)
  end

  @impl true
  def write(conn, collection, %{} = doc) do
    ensure(conn, collection)
    id = Map.get(doc, "id") || Map.get(doc, :id) || uid()
    doc = Map.put(doc, "id", id)

    %{} =
      Postgrex.query!(
        conn,
        ~s|INSERT INTO "#{collection}" (id, doc) VALUES ($1, $2)
           ON CONFLICT (id) DO UPDATE SET doc = EXCLUDED.doc|,
        [id, doc]
      )

    {:ok, doc}
  end

  @impl true
  def read(conn, collection, query) do
    ensure(conn, collection)
    {where, params} = where_of(query)
    res = Postgrex.query!(conn, ~s|SELECT doc FROM "#{collection}"| <> where, params)
    {:ok, Enum.map(res.rows, fn [doc] -> doc end)}
  end

  @impl true
  def query(conn, raw, params) do
    res = Postgrex.query!(conn, raw, params)
    {:ok, res.rows}
  end

  @impl true
  def close(conn), do: GenServer.stop(conn)

  defp ensure(conn, collection),
    do: Postgrex.query!(conn, ~s|CREATE TABLE IF NOT EXISTS "#{collection}" (id text primary key, doc jsonb)|, [])

  # Equality filter on JSON fields via the jsonb ->> operator.
  defp where_of(query) when map_size(query) == 0, do: {"", []}

  defp where_of(query) do
    {clauses, params} =
      query
      |> Enum.with_index(1)
      |> Enum.map(fn {{k, v}, i} -> {~s|doc->>'#{k}' = $#{i}|, to_string(v)} end)
      |> Enum.unzip()

    {" WHERE " <> Enum.join(clauses, " AND "), params}
  end

  defp parse_dsn(dsn) do
    uri = URI.parse(dsn)
    [user, pass] = String.split(uri.userinfo || "postgres:", ":", parts: 2) ++ [""]

    [
      hostname: uri.host || "localhost",
      port: uri.port || 5432,
      username: user,
      password: pass,
      database: String.trim_leading(uri.path || "/postgres", "/")
    ]
  end

  defp uid, do: Integer.to_string(System.unique_integer([:positive]))
end
