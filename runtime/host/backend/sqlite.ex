defmodule Workbooks.Backend.SQLite do
  @moduledoc """
  BYOD SQLite backend (L2) — the local/dev default, over `exqlite`. A collection
  is a table of `(id TEXT PRIMARY KEY, doc TEXT)` holding JSON docs; `write`
  upserts, `read` filters by an equality map, `query` runs raw SQL. The same
  engine the Instance VFS uses; durability off-box is Litestream's job (L2),
  not this module's.
  """
  @behaviour Workbooks.Backend
  alias Exqlite.Sqlite3

  @impl true
  def init(opts), do: Sqlite3.open(Keyword.get(opts, :path, ":memory:"))

  @impl true
  def write(conn, collection, %{} = doc) do
    ensure(conn, collection)
    id = Map.get(doc, "id") || Map.get(doc, :id) || uid()
    json = Jason.encode!(Map.put(doc, "id", id))
    {:ok, stmt} = Sqlite3.prepare(conn, ~s|INSERT OR REPLACE INTO "#{collection}" (id, doc) VALUES (?1, ?2)|)
    :ok = Sqlite3.bind(stmt, [id, json])
    :done = Sqlite3.step(conn, stmt)
    Sqlite3.release(conn, stmt)
    {:ok, Jason.decode!(json)}
  end

  @impl true
  def read(conn, collection, query) do
    ensure(conn, collection)
    {where, params} = where_of(query)
    raw = ~s|SELECT doc FROM "#{collection}"| <> where
    with {:ok, rows} <- raw(conn, raw, params),
         do: {:ok, Enum.map(rows, fn [json] -> Jason.decode!(json) end)}
  end

  @impl true
  def query(conn, raw, params), do: raw(conn, raw, params)

  @impl true
  def close(conn), do: Sqlite3.close(conn)

  defp raw(conn, sql, params) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql),
         :ok <- Sqlite3.bind(stmt, params),
         {:ok, rows} <- Sqlite3.fetch_all(conn, stmt) do
      Sqlite3.release(conn, stmt)
      {:ok, rows}
    end
  end

  # Collections are created on first touch — schemaless from the caller's view.
  defp ensure(conn, collection),
    do: Sqlite3.execute(conn, ~s|CREATE TABLE IF NOT EXISTS "#{collection}" (id TEXT PRIMARY KEY, doc TEXT)|)

  # A query map becomes an equality filter on JSON fields via SQLite json_extract.
  defp where_of(query) when map_size(query) == 0, do: {"", []}

  defp where_of(query) do
    {clauses, params} =
      query
      |> Enum.map(fn {k, v} -> {~s|json_extract(doc, '$.#{k}') = ?|, v} end)
      |> Enum.unzip()

    {" WHERE " <> Enum.join(clauses, " AND "), params}
  end

  defp uid, do: Integer.to_string(System.unique_integer([:positive]))
end
