defmodule Nexus.Compile.Store do
  @moduledoc """
  The content-addressed store for compiled components — **two tiers**:

    * **local** (always): a hot directory of `.component.wasm` blobs. Fast hits, survives within a
      machine. This is the floor; with no remote configured the store is local-only.
    * **remote** (optional): any S3-compatible, **egress-free** object store (MinIO, Backblaze, …)
      behind `Nexus.S3`. Durable + shared across every machine/tenant, so "compile once" is
      fleet-wide, not per-box — and survives scale-to-zero machine churn.

  Blobs are immutable (key = content hash), so the tiers never need invalidation or coordination.

  `component-cache` (in `deploy`) selects the mode:

      component-cache="build/components"           # local dir → local-only
      component-cache="s3://my-bucket/components"   # remote (s3://; r2:// is a deprecated alias) + local hot tier
        component-cache-endpoint="https://<your-s3-endpoint>"
        component-cache-region="auto"

  fetch order: local → remote (pull into local) → :miss. put: local + (best-effort) remote push.
  A remote that's down/misconfigured NEVER fails a build — it degrades to local-only and logs.
  """
  require Logger

  @doc "Look up a key. {:ok, local_path} on a local OR remote hit (pulled local); :miss otherwise."
  def fetch(key) do
    lp = local_path(key)

    cond do
      File.exists?(lp) -> {:ok, lp}
      pull(key, lp) == :ok -> {:ok, lp}
      true -> :miss
    end
  end

  @doc "Store a freshly-built component at `src` under `key`. Returns the canonical local path."
  def put(key, src) do
    lp = local_path(key)
    File.mkdir_p!(Path.dirname(lp))
    tmp = lp <> ".#{System.unique_integer([:positive])}.tmp"
    File.cp!(src, tmp)
    File.rename!(tmp, lp)
    # Preserve the WASHY sidecars next to the cached component: the CORE module (`src` minus
    # `.component.wasm`, which the component wraps) + the `.washy` return-type marker — so SSR can run a
    # numeric `render` on the dense Washy lane. Best-effort; absence just means not Washy-eligible.
    core = String.replace_suffix(src, ".component.wasm", "")
    if core != src and File.exists?(core), do: File.cp!(core, String.replace_suffix(lp, ".component.wasm", ".core.wasm"))
    if File.exists?(src <> ".washy"), do: File.cp!(src <> ".washy", String.replace_suffix(lp, ".component.wasm", ".washy"))
    push(key, lp)
    lp
  end

  # ── tiers ─────────────────────────────────────────────────────────────────────────────────────
  defp local_path(key), do: Path.join(local_dir(), key <> ".component.wasm")

  # Local-only mode keeps blobs at the configured dir; remote mode uses a default hot dir on the
  # persistent data volume (survives VM/machine restart — losing it only forces a re-pull from the
  # durable remote, never a recompile).
  defp local_dir do
    case spec() do
      {:local, dir} -> dir
      {:remote, _} -> Path.join([Nexus.Config.data_dir(), "build", "components"])
    end
  end

  defp pull(key, lp) do
    with {:remote, loc} <- spec(),
         true <- Nexus.S3.configured?(),
         {:ok, body} <- Nexus.S3.get(loc, blob_key(loc, key)) do
      File.mkdir_p!(Path.dirname(lp))
      tmp = lp <> ".#{System.unique_integer([:positive])}.tmp"
      File.write!(tmp, body)
      File.rename!(tmp, lp)
      :ok
    else
      {:error, :not_found} -> :miss
      {:error, reason} -> Logger.warning("component cache: remote pull failed: #{inspect(reason)}"); :miss
      _ -> :miss
    end
  end

  defp push(key, lp) do
    with {:remote, loc} <- spec(),
         true <- Nexus.S3.configured?() do
      case Nexus.S3.put(loc, blob_key(loc, key), File.read!(lp)) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("component cache: remote push failed: #{inspect(reason)}"); :ok
      end
    else
      _ -> :ok
    end
  end

  defp blob_key(%{prefix: p}, key) do
    [p, key <> ".component.wasm"] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("/")
  end

  # Parse `component-cache` into {:local, dir} | {:remote, %{bucket, prefix, endpoint, region}}.
  defp spec do
    case Nexus.Config.component_cache() do
      "s3://" <> rest -> remote(rest)
      # deprecated alias of s3:// — kept for back-compat with existing configs
      "r2://" <> rest -> remote(rest)
      dir -> {:local, dir}
    end
  end

  defp remote(rest) do
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
