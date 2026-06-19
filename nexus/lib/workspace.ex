defmodule Nexus.Workspace do
  @moduledoc """
  The storage / backup layer over a managed workspace repo (`Nexus.Git`).

  A workspace's durable, portable backup is a **git bundle** — one file holding the
  whole history. The bundle goes to the workspace's remote backend:

    * **GitHub** (when the user connects it) — their monorepo of workspaces IS the
      store; we keep nothing. *(remote backend: next.)*
    * **our cold storage** otherwise — this module's backend. The local tier writes
      to a `backups/` dir on the persistent data volume (`Nexus.Config.data_dir/0`),
      exactly like the compile cache's local tier; the S3/R2 tier wires on top.

  When GitHub isn't connected, cold-storage bytes count toward the tenant's storage
  quota (see `Nexus.Capacity`); `backup/2` returns the byte size for that metering.
  """
  alias Nexus.Git

  @doc "Bundle the whole repo history into bytes — the durable, portable backup unit."
  def bundle(dir) do
    Git.ensure(dir)
    tmp = Path.join(System.tmp_dir!(), "wb_#{System.unique_integer([:positive])}.bundle")

    try do
      case System.cmd("git", ["bundle", "create", tmp, "--all"], cd: dir, stderr_to_stdout: true) do
        {_, 0} -> {:ok, File.read!(tmp)}
        {out, _} -> {:error, out}
      end
    after
      File.rm(tmp)
    end
  end

  @doc "Back the workspace up to cold storage at `key`. `{:ok, byte_size}` (for metering) | `{:error, reason}`."
  def backup(dir, key) when is_binary(key) do
    with {:ok, bytes} <- bundle(dir),
         :ok <- Nexus.S3.Local.put(store_dir(), key, bytes) do
      {:ok, byte_size(bytes)}
    end
  end

  @doc "Restore a cold-storage backup into `dir` (created fresh from the bundle)."
  def restore(key, dir) when is_binary(key) do
    with {:ok, bytes} <- Nexus.S3.Local.get(store_dir(), key) do
      tmp = Path.join(System.tmp_dir!(), "wb_#{System.unique_integer([:positive])}.bundle")
      File.write!(tmp, bytes)
      File.mkdir_p!(dir)

      try do
        case System.cmd("git", ["clone", "-q", tmp, dir], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, _} -> {:error, out}
        end
      after
        File.rm(tmp)
      end
    end
  end

  @doc "Size of the workspace's backup in bytes — what counts toward the storage quota."
  def size(dir) do
    case bundle(dir) do
      {:ok, bytes} -> byte_size(bytes)
      _ -> 0
    end
  end

  defp store_dir, do: Path.join(Nexus.Config.data_dir(), "backups")
end
