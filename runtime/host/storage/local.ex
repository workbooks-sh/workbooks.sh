defmodule Workbooks.Storage.Local do
  @moduledoc """
  Filesystem blob storage — the default `WB_STORAGE=local` adapter. Blobs live
  under `<WB_DATA>/<tenant>/blobs/<key>`. The simplest durable deploy is this with
  `WB_DATA` mounted on a Fly volume: persistent across redeploys, ZERO code change
  — the volume IS the storage. (The signing key already persists via WB_SIGNING_KEY;
  this is the rest of the tenant's bytes.)
  """
  @behaviour Workbooks.Storage

  defp base(tenant), do: Path.join([System.get_env("WB_DATA", "tmp/data"), tenant, "blobs"])
  defp path(tenant, key), do: Path.join(base(tenant), key)

  @impl true
  def put(tenant, key, bytes) do
    p = path(tenant, key)
    File.mkdir_p!(Path.dirname(p))
    File.write(p, bytes)
  end

  @impl true
  def get(tenant, key) do
    case File.read(path(tenant, key)) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> :error
    end
  end

  @impl true
  def list(tenant, prefix) do
    root = base(tenant)

    Path.join([root, prefix, "**/*"])
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
  end

  @impl true
  def delete(tenant, key) do
    # Fail-CLOSED: only report :ok when the object is actually gone. ENOENT (already
    # absent) counts as gone; any other rm error surfaces so the facade keeps the
    # bytes charged in the ledger.
    case File.rm(path(tenant, key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = err -> err
    end
  end
end
