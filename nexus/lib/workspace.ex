defmodule Nexus.Workspace do
  @moduledoc """
  Storage / backup over a managed workspace repo (`Nexus.Git`) — built ON the
  existing storage systems, not a new one.

  A workspace's durable backup is a **git bundle** (the whole history in one file).
  It's stored as a **no-expiry entry in the tenant-scoped cold store**
  (`Nexus.Cache.Cold`, namespace `"workspaces"`): the local tier lives on the data
  volume, and it routes to the R2/S3 remote automatically when `cache-cold` is an
  `r2://`/`s3://` URI — the *same* two-tier, tenant-isolated backend the cache and
  the compile store already use.

  `backup/3` returns the bundle's byte size for quota metering — cold-storage bytes
  count toward the tenant's storage limit when GitHub isn't connected. The
  GitHub-remote backend (push the user's monorepo) wires on top of this.
  """
  alias Nexus.Git
  alias Nexus.Cache.Cold

  @ns "workspaces"

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

  @doc """
  Back the workspace up to the tenant's cold store at `key`. `{:ok, byte_size}` (for
  metering) | `{:error, reason}`. Stored with no expiry — durable, not a TTL entry.
  """
  def backup(tenant, dir, key) when is_binary(key) do
    with {:ok, bytes} <- bundle(dir),
         :ok <- Cold.put(tenant, @ns, key, {bytes, :infinity}) do
      {:ok, byte_size(bytes)}
    end
  end

  @doc "Restore a tenant's cold-store backup into `dir` (created fresh from the bundle)."
  def restore(tenant, key, dir) when is_binary(key) do
    case Cold.get(tenant, @ns, key) do
      {:ok, {bytes, _expires}} -> clone(bytes, dir)
      :miss -> {:error, :not_found}
      other -> other
    end
  end

  @doc "Size of the workspace's backup in bytes — what counts toward the storage quota."
  def size(dir) do
    case bundle(dir) do
      {:ok, bytes} -> byte_size(bytes)
      _ -> 0
    end
  end

  defp clone(bytes, dir) do
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
