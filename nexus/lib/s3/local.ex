defmodule Nexus.S3.Local do
  @moduledoc """
  A filesystem object store that fakes an S3 bucket for dev — the local stand-in behind the
  `Nexus.Objects` seam. Objects are plain files under a base directory (the workbook's
  `~/.workbooks/dev/s3/<uuid>/` folder, `:s3_local_dir`); keys map straight to relative paths, so
  the faked bucket is just a folder you can open in Finder.

  Same op shapes as the real `Nexus.S3` client (`get/2` → `{:ok, body}`, `put/3` → `:ok`,
  `head/2` → `:ok | :not_found`) plus `list/2` + `delete/2`, which the local store can do cheaply.
  """

  @doc "GET an object → `{:ok, body} | {:error, :not_found}`."
  def get(base, key) do
    path = safe(base, key)

    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "PUT bytes → `:ok | {:error, reason}` (parents created)."
  def put(base, key, body) do
    path = safe(base, key)
    File.mkdir_p!(Path.dirname(path))
    File.write(path, body)
  end

  @doc "HEAD → `:ok | :not_found`."
  def head(base, key), do: if(File.exists?(safe(base, key)), do: :ok, else: :not_found)

  @doc "DELETE → `:ok` (idempotent)."
  def delete(base, key) do
    File.rm(safe(base, key))
    :ok
  end

  @doc "List object keys under `prefix` (relative to the bucket root)."
  def list(base, prefix \\ "") do
    root = Path.expand(base)

    Path.wildcard(Path.join(root, "**"))
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.sort()
  end

  # A key maps to a path UNDER base — strip any `.`/`..` segment so a key can never escape the bucket.
  defp safe(base, key) do
    rel =
      key
      |> to_string()
      |> String.split("/")
      |> Enum.reject(&(&1 in ["", ".", ".."]))
      |> Path.join()

    Path.join(Path.expand(base), rel)
  end
end
