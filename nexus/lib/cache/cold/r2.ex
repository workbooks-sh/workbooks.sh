defmodule Nexus.Cache.Cold.R2 do
  @moduledoc """
  R2/S3 `Nexus.Cache.Cold` provider — the egress-free object store, riding the SAME `Nexus.S3` client
  the compile store uses. Its `bucket/prefix` come from the `cache-cold` `<work-deploy>` knob (an
  `r2://bucket/prefix` or `s3://…` URI). One object per cache entry at the tenant-scoped path from
  `Nexus.Cache.Cold.object_path/3`.

  With no S3 creds (`Nexus.S3.configured?/0` false) or a local-only `component-cache`, the cold tier
  is simply absent: `get` → `:miss`, `put`/`delete` → `:ok` no-ops. A cache hot-miss then just stays
  a miss — never an error — exactly the graceful-degrade contract the compile store follows.
  """
  @behaviour Nexus.Cache.Cold
  require Logger

  alias Nexus.Cache.Cold

  @impl true
  def get(tenant, ns, key) do
    with {:ok, loc} <- remote(),
         {:ok, body} <- Nexus.S3.get(loc, blob_key(loc, tenant, ns, key)) do
      {:ok, Cold.decode(body)}
    else
      _ -> :miss
    end
  end

  @impl true
  def put(tenant, ns, key, entry) do
    with {:ok, loc} <- remote() do
      case Nexus.S3.put(loc, blob_key(loc, tenant, ns, key), Cold.encode(entry)) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("cache cold: put failed: #{inspect(reason)}"); :ok
      end
    else
      _ -> :ok
    end
  end

  @impl true
  def delete(tenant, ns, key) do
    # No DELETE op on the minimal S3 client; overwrite with an already-expired tombstone so a
    # subsequent get treats it as a miss (lazy expiry handles the read side).
    put(tenant, ns, key, {"", 0})
  end

  # ── remote spec (mirrors Nexus.Compile.Store.spec/0, R2/S3 + creds required) ─────────────────────
  defp remote do
    case spec() do
      {:remote, loc} -> if Nexus.S3.configured?(), do: {:ok, loc}, else: :none
      _ -> :none
    end
  end

  defp blob_key(%{prefix: p}, tenant, ns, key) do
    [p, Cold.object_path(tenant, ns, key)] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("/")
  end

  defp spec do
    case Nexus.Config.cache_cold() do
      "s3://" <> rest -> remote_loc(rest)
      "r2://" <> rest -> remote_loc(rest)
      _ -> {:local, nil}
    end
  end

  defp remote_loc(rest) do
    {bucket, prefix} =
      case String.split(rest, "/", parts: 2) do
        [b, p] -> {b, p}
        [b] -> {b, ""}
      end

    {:remote,
     %{
       bucket: bucket,
       prefix: prefix,
       endpoint: Nexus.Config.component_cache_endpoint(),
       region: Nexus.Config.component_cache_region()
     }}
  end
end
