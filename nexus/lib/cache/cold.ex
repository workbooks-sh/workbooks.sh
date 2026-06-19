defmodule Nexus.Cache.Cold do
  @moduledoc """
  The **cold tier** seam for `Nexus.Cache` — a tenant-scoped, egress-free object store one entry deep.

  An entry is `{value :: binary, expires_at :: integer | :infinity}` stored at a tenant-scoped object
  path `cache/<tenant>/<namespace>/<key-hash>`.

  **The cold tier abstracts over the deploy target** — two routes behind ONE interface, picked by
  config (`cache-cold` in `<work-deploy>`), exactly the way `Nexus.Compile.Store` switches on
  `component-cache`. The hot/cold logic in `Nexus.Cache.Tiered` never names which backend; it just
  calls this seam:

    * `Nexus.Cache.Cold.Local` (DEFAULT) — object files under `Nexus.Config.data_dir()` (the mounted
      `WB_DATA` volume, e.g. `/data` in the libkrun microVM / Fly machine). Durable across machine
      restarts. The **local route**, and the safe default when no R2 is configured.
    * `Nexus.Cache.Cold.R2` — the egress-free S3-compatible object store, reusing the compile store's
      `Nexus.S3` client/config. The **cloud route** (Fly).

  Selection: `cache-cold` is a local path (→ Local) or an `r2://`/`s3://` URI (→ R2). The operator
  picks cloud-vs-local once in the deploy HTML; the same cache code runs either way. This also makes
  tests trivial — `Cold.Local` pointed at a tmp dir IS the cold double, no network and no mock.

  The tenant is part of the object PATH (not just a logical filter) — one tenant can never address
  another's cold object. Isolation is structural, the same property `Nexus.Store` enforces for rows.
  """

  @type tenant :: String.t()
  @type entry :: {binary, integer | :infinity}

  @callback get(tenant, namespace :: String.t(), key :: String.t()) :: {:ok, entry} | :miss
  @callback put(tenant, namespace :: String.t(), key :: String.t(), entry) :: :ok
  @callback delete(tenant, namespace :: String.t(), key :: String.t()) :: :ok

  @doc """
  The configured cold-tier provider. An explicit `config :nexus, :cache_cold, Module` override wins
  (an embedder may force a provider); otherwise it's resolved from the `cache-cold` `<work-deploy>`
  knob — an `r2://`/`s3://` URI → `Nexus.Cache.Cold.R2`, any other (filesystem path) → `…Local`.
  """
  def provider do
    case Application.get_env(:nexus, :cache_cold) do
      mod when is_atom(mod) and not is_nil(mod) ->
        mod

      nil ->
        case Nexus.Config.cache_cold() do
          "r2://" <> _ -> Nexus.Cache.Cold.R2
          "s3://" <> _ -> Nexus.Cache.Cold.R2
          _ -> Nexus.Cache.Cold.Local
        end
    end
  end

  def get(tenant, ns, key), do: provider().get(tenant, ns, key)
  def put(tenant, ns, key, entry), do: provider().put(tenant, ns, key, entry)
  def delete(tenant, ns, key), do: provider().delete(tenant, ns, key)

  @doc """
  The tenant-scoped object path for an entry. The key is hashed (opaque + filesystem/URL-safe; a raw
  key could contain `/` or arbitrary bytes), but the **tenant and namespace are plain path segments**
  so a tenant's keyspace is a directory it alone can address.
  """
  def object_path(tenant, ns, key) do
    hash = Base.encode16(:crypto.hash(:sha256, key), case: :lower)
    Enum.join(["cache", seg(tenant), seg(ns), hash], "/")
  end

  # path segments are themselves sanitized so a crafted tenant/namespace can't escape its prefix.
  defp seg(s), do: s |> to_string() |> String.replace(~r{[^A-Za-z0-9_.-]}, "_")

  @doc "Encode an entry to bytes: `<expires_at>\\n<value>` (expires_at = integer secs or `inf`)."
  def encode({value, expires_at}) when is_binary(value) do
    exp = if expires_at == :infinity, do: "inf", else: Integer.to_string(expires_at)
    exp <> "\n" <> value
  end

  @doc "Decode bytes produced by `encode/1` back to an `{value, expires_at}` entry."
  def decode(bin) when is_binary(bin) do
    case :binary.split(bin, "\n") do
      [exp, value] ->
        expires_at = if exp == "inf", do: :infinity, else: String.to_integer(exp)
        {value, expires_at}

      _ ->
        {bin, :infinity}
    end
  end
end
