defmodule Workbooks.VFS do
  @moduledoc """
  A Workbook's virtual file system — SQLite-backed, one db file per Instance.
  Paths live in named *volumes* (session canon, wb-11ck.17):
    * `workspace` — the Workbook's files (the working tree). Persists.
    * `memory`    — agent long-term memory. Persists across freeze/resume.
    * `tmp`       — scratch. Cleared on resume (see `Lifecycle`).
  A volume is the `(volume, path)` key in one table — one file, one connection;
  durability off-box is Litestream's job. The Dock's raw `vfs-query` sees the
  `volume` column, so a component can scope a query to any volume.
  """
  alias Exqlite.Sqlite3

  @volumes ~w(workspace memory tmp)
  @default "workspace"

  def volumes, do: @volumes

  def open(path) do
    {:ok, conn} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(conn, """
      CREATE TABLE IF NOT EXISTS vfs (
        volume TEXT NOT NULL, path TEXT NOT NULL, content BLOB, mtime INTEGER,
        PRIMARY KEY (volume, path)
      )
      """)

    {:ok, conn}
  end

  def put(conn, path, content, volume \\ @default) when volume in @volumes do
    {:ok, stmt} =
      Sqlite3.prepare(conn, "INSERT OR REPLACE INTO vfs (volume, path, content, mtime) VALUES (?1, ?2, ?3, ?4)")

    :ok = Sqlite3.bind(stmt, [volume, path, content, System.system_time(:second)])
    :done = Sqlite3.step(conn, stmt)
    Sqlite3.release(conn, stmt)
  end

  def get(conn, path, volume \\ @default) do
    {:ok, stmt} = Sqlite3.prepare(conn, "SELECT content FROM vfs WHERE volume = ?1 AND path = ?2")
    :ok = Sqlite3.bind(stmt, [volume, path])

    res =
      case Sqlite3.step(conn, stmt) do
        {:row, [content]} -> {:ok, content}
        :done -> :error
      end

    Sqlite3.release(conn, stmt)
    res
  end

  @doc "Clear a volume (e.g. `tmp` on resume). Returns :ok."
  def clear(conn, volume) when volume in @volumes do
    {:ok, stmt} = Sqlite3.prepare(conn, "DELETE FROM vfs WHERE volume = ?1")
    :ok = Sqlite3.bind(stmt, [volume])
    :done = Sqlite3.step(conn, stmt)
    Sqlite3.release(conn, stmt)
  end

  @doc """
  Return VFS bytes with private volumes (agent `memory`, `tmp`) removed — only
  `Workbooks.Private.public_volumes/0` survive. Used on egress so a shared
  container ships its working tree, never the session that produced it.
  """
  def public_only(bytes) when is_binary(bytes) do
    tmp = Path.join(System.tmp_dir!(), "vfs-pub-#{:erlang.phash2(bytes)}.sqlite")
    File.write!(tmp, bytes)
    {:ok, c} = Sqlite3.open(tmp)
    keep = Enum.map_join(Workbooks.Private.public_volumes(), ",", &"'#{&1}'")
    Sqlite3.execute(c, "DELETE FROM vfs WHERE volume NOT IN (#{keep})")
    Sqlite3.execute(c, "VACUUM")
    Sqlite3.close(c)
    out = File.read!(tmp)
    File.rm(tmp)
    out
  rescue
    _ -> bytes
  end

  @doc """
  Run a read query against the Instance VFS and return rows as a JSON array of
  arrays — the `vfs-query` Dock import. A bad query returns a JSON error object,
  never a host crash (the Instance must not be able to take down its engine).
  """
  def query_json(conn, sql) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql),
         {:ok, rows} <- Sqlite3.fetch_all(conn, stmt) do
      Sqlite3.release(conn, stmt)
      Jason.encode!(rows)
    else
      {:error, reason} -> Jason.encode!(%{error: to_string(reason)})
    end
  end
end
