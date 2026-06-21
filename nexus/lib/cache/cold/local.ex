defmodule Nexus.Cache.Cold.Local do
  @moduledoc """
  Filesystem `Nexus.Cache.Cold` provider — the default when `cache-cold` is a plain path (not an
  `s3://` URI). One file per cache entry under `<cache-cold>/<object_path>`, where
  `object_path` is the SAME tenant-scoped path the S3 provider uses — so the tenant-isolation property
  (a tenant's keyspace is a directory it alone addresses) is identical in both backends.

  Durable across machine restarts when the path is on the mounted data volume (the `Nexus.Config`
  default `<data_dir>/cache`), and the network-free cold tier for the local/libkrun deploy route.
  """
  @behaviour Nexus.Cache.Cold

  alias Nexus.Cache.Cold

  @impl true
  def get(tenant, ns, key) do
    case File.read(path(tenant, ns, key)) do
      {:ok, bin} -> {:ok, Cold.decode(bin)}
      _ -> :miss
    end
  end

  @impl true
  def put(tenant, ns, key, entry) do
    p = path(tenant, ns, key)
    File.mkdir_p!(Path.dirname(p))
    tmp = p <> ".#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp, Cold.encode(entry))
    File.rename!(tmp, p)
    :ok
  end

  @impl true
  def delete(tenant, ns, key) do
    File.rm(path(tenant, ns, key))
    :ok
  end

  defp path(tenant, ns, key) do
    Path.join(Nexus.Config.cache_cold(), Cold.object_path(tenant, ns, key))
  end
end
