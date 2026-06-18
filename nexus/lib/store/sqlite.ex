defmodule Nexus.Store.Sqlite do
  @moduledoc """
  A durable `Nexus.Store` backend on SQLite (via `exqlite`) — the "local, but survives a restart"
  option behind the universal seam. One table per resource, each row the serialized struct (so
  enum atoms and the full shape round-trip exactly). Swap it in with
  `config :nexus, store_adapter: Nexus.Store.Sqlite` (db path via `:sqlite_path`, default a temp file).

  NOTE: rows are stored as a term blob — durable + correct, but not yet field-queryable in SQL.
  Column-mapping (a column per `__fields__` entry, so `WHERE`/`ORDER BY` work) is the enhancement;
  the same applies to a Postgres or wasm-SQL adapter behind these four callbacks.
  """
  @behaviour Nexus.Store
  alias Exqlite.Sqlite3

  @impl true
  def create(resource, attrs) do
    case Nexus.Resource.validate(resource, attrs) do
      {:ok, row} ->
        with_conn(fn conn ->
          ensure_table(conn, resource)
          {:ok, stmt} = Sqlite3.prepare(conn, "INSERT INTO #{tbl(resource)} (data) VALUES (?1)")
          :ok = Sqlite3.bind(stmt, [:erlang.term_to_binary(row)])
          :done = Sqlite3.step(conn, stmt)
        end)

        {:ok, row}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def all(resource) do
    with_conn(fn conn ->
      ensure_table(conn, resource)
      {:ok, stmt} = Sqlite3.prepare(conn, "SELECT data FROM #{tbl(resource)} ORDER BY id")
      {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
      Enum.map(rows, fn [blob] -> :erlang.binary_to_term(blob) end)
    end)
  end

  @impl true
  def count(resource), do: length(all(resource))

  @impl true
  def clear(resource) do
    with_conn(fn conn -> ensure_table(conn, resource) && Sqlite3.execute(conn, "DELETE FROM #{tbl(resource)}") end)
    :ok
  end

  defp with_conn(fun) do
    {:ok, conn} = Sqlite3.open(db_path())

    try do
      fun.(conn)
    after
      Sqlite3.close(conn)
    end
  end

  defp ensure_table(conn, resource) do
    Sqlite3.execute(conn, "CREATE TABLE IF NOT EXISTS #{tbl(resource)} (id INTEGER PRIMARY KEY, data BLOB)")
  end

  defp tbl(resource), do: "r_" <> (resource |> Module.split() |> Enum.join("_") |> String.downcase())

  defp db_path, do: Application.get_env(:nexus, :sqlite_path, Path.join(System.tmp_dir!(), "nexus.db"))
end
