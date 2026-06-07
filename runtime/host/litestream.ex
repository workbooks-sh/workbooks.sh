defmodule Workbooks.Litestream do
  @moduledoc """
  Continuous off-box durability for an Instance VFS (wb-11ck.19). Litestream
  streams a WAL-mode SQLite db's changes to a replica and restores from it. The
  replica URL is `file://...` for local/dev and `s3://bucket/path` for prod (R2)
  — same command, the only difference is the URL + AWS creds in the environment.

  Replication is a long-lived process (a Port tied to the engine); restore is a
  one-shot. The VFS must be in WAL mode for Litestream to capture changes.
  """
  @local Path.expand("~/.local/bin/litestream")

  @doc "Put a SQLite connection in WAL mode (required before replicating)."
  def enable_wal(conn), do: Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")

  @doc "Start continuous replication of `db_path` to `replica_url`. Returns a Port."
  def replicate(db_path, replica_url) do
    Port.open({:spawn_executable, bin()}, [
      :binary,
      :exit_status,
      args: ["replicate", db_path, replica_url]
    ])
  end

  @doc "Stop a replication Port."
  def stop(port) when is_port(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end

  @doc "Restore the latest snapshot from `replica_url` into `out_path`. One-shot."
  def restore(replica_url, out_path) do
    case System.cmd(bin(), ["restore", "-o", out_path, replica_url], stderr_to_stdout: true) do
      {_, 0} -> {:ok, out_path}
      {err, _} -> {:error, err}
    end
  end

  defp bin do
    System.find_executable("litestream") || @local
  end
end
