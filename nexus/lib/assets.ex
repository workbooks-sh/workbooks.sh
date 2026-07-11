defmodule Nexus.Assets do
  @moduledoc """
  Generated-asset blob store — the home for bytes an agent PRODUCES (a generated image / clip / audio),
  as opposed to `Nexus.Store` (typed rows) or the git-backed workspace tree (authored source).

  Bytes land under `<data_dir>/assets/<tenant>/<id>.<ext>` (the persistent volume) and are served
  read-only at `/assets/<tenant>/<id>.<ext>` by `Nexus.Server`. Generic mechanism — no Workbooks
  business — so any workbook that generates a binary uses the same store + URL.

  Remote tier (optional): `deploy asset-store="s3://bucket/prefix"` write-throughs every `put` to
  the S3-compatible object store via `Nexus.S3` (same creds seam as the cold cache) and falls back
  to it on a local `read` miss (fresh machine / swapped volume), rematerializing locally. When the
  deploy also declares `asset-store-public="https://…"` (a public bucket host or custom domain),
  `put` returns THAT url — the bytes then egress from the object store's edge, never this nexus.
  Public serving is opt-in and capability-URL-secured (ids are 128-bit random); the `/assets/…`
  route and its tenant scoping stay intact for locally-addressed and legacy assets. Remote failures
  degrade gracefully: the local write is the source of truth, so a failed upload just means local
  serving — never an error to the caller.
  """
  require Logger

  @doc """
  May a caller whose authenticated tenant is `session_tenant` read assets under URL tenant `url_tenant`?

  On a MULTI-tenant nexus the URL tenant must equal the session tenant — otherwise `/assets/<other>/…`
  is a cross-tenant read of another org's generated blobs (the tenant came from the URL, not the
  session). On a single-tenant nexus (`multi? == false`) there is exactly one tenant, so serving is
  unchanged. (red-team wb-0w41)
  """
  def may_serve?(session_tenant, url_tenant, multi?) do
    not multi? or session_tenant == url_tenant
  end

  @doc "Directory holding a tenant's generated assets."
  def dir(tenant), do: Path.join([Nexus.Config.data_dir(), "assets", safe(tenant)])

  @doc """
  Persist `bytes` (a binary) for `tenant`, inferring the extension from `content_type`. Returns
  `{:ok, %{id, name, path, url, content_type, bytes}}` — `url` is the browser-reachable `/assets/…` path.
  """
  def put(tenant, bytes, content_type) when is_binary(bytes) do
    ext = ext_for(content_type)
    id = gen_id()
    name = "#{id}.#{ext}"
    d = dir(tenant)
    File.mkdir_p!(d)
    File.write!(Path.join(d, name), bytes)

    {:ok,
     %{
       id: id,
       name: name,
       path: Path.join(d, name),
       url: remote_put(tenant, name, bytes) || "/assets/#{safe(tenant)}/#{name}",
       content_type: content_type,
       bytes: byte_size(bytes)
     }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Read a stored asset back: `{:ok, bytes, content_type}` or `:error`. `name` is basename-sanitized."
  def read(tenant, name) do
    base = Path.basename(to_string(name))
    path = Path.join(dir(tenant), base)

    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes, content_type_for(path)}
      _ -> remote_read(tenant, base, path)
    end
  end

  # ── remote tier (asset-store="s3://bucket/prefix" in deploy; absent ⇒ all no-ops) ──────────────

  # Write-through. Returns the PUBLIC url when the deploy declares `asset-store-public` and the
  # upload succeeded — else nil (caller hands out the local `/assets/…` path).
  defp remote_put(tenant, name, bytes) do
    with {:ok, loc} <- remote() do
      case s3().put(loc, object_key(tenant, name), bytes) do
        :ok ->
          public_url(loc, tenant, name)

        {:error, reason} ->
          Logger.warning("assets: remote put failed (serving locally): #{inspect(reason)}")
          nil
      end
    else
      _ -> nil
    end
  end

  # Local miss → remote fetch → rematerialize (fresh machine / swapped volume), so the NEXT read
  # is local again. A remote miss stays :error, exactly like the pure-local store.
  defp remote_read(tenant, name, path) do
    with {:ok, loc} <- remote(),
         {:ok, bytes} <- s3().get(loc, object_key(tenant, name)) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
      {:ok, bytes, content_type_for(path)}
    else
      _ -> :error
    end
  end

  defp remote do
    case Nexus.Config.asset_store() do
      "s3://" <> rest -> remote_loc(rest)
      # deprecated alias of s3:// — same back-compat contract as the cold cache
      "r2://" <> rest -> remote_loc(rest)
      _ -> :none
    end
  end

  defp remote_loc(rest) do
    if s3().configured?() do
      {bucket, prefix} =
        case String.split(rest, "/", parts: 2) do
          [b, p] -> {b, p}
          [b] -> {b, ""}
        end

      {:ok,
       %{
         bucket: bucket,
         prefix: prefix,
         endpoint: Nexus.Config.asset_store_endpoint(),
         region: Nexus.Config.asset_store_region()
       }}
    else
      :none
    end
  end

  # `Nexus.S3` prepends the loc's prefix — the key is just the tenant-scoped object path.
  defp object_key(tenant, name), do: "#{safe(tenant)}/#{name}"

  defp public_url(%{prefix: prefix}, tenant, name) do
    case Nexus.Config.asset_store_public() do
      base when is_binary(base) and base != "" ->
        [String.trim_trailing(base, "/"), prefix, object_key(tenant, name)]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("/")

      _ ->
        nil
    end
  end

  defp s3, do: Application.get_env(:nexus, :assets_s3_client, Nexus.S3)

  # Tenant goes into a filesystem path + a URL — keep it to a safe slug.
  defp safe(t) do
    case t |> to_string() |> String.replace(~r/[^a-zA-Z0-9_.-]/, "") do
      "" -> "default"
      s -> s
    end
  end

  defp gen_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @ext %{
    "image/png" => "png", "image/jpeg" => "jpg", "image/webp" => "webp", "image/gif" => "gif",
    "image/svg+xml" => "svg", "video/mp4" => "mp4", "video/webm" => "webm",
    "audio/mpeg" => "mp3", "audio/mp3" => "mp3", "audio/wav" => "wav", "audio/ogg" => "ogg",
    "application/pdf" => "pdf"
  }
  defp ext_for(ct), do: Map.get(@ext, to_string(ct) |> String.split(";") |> List.first(), "bin")

  @ct_by_ext @ext |> Enum.map(fn {ct, e} -> {e, ct} end) |> Map.new()
  defp content_type_for(path) do
    Map.get(@ct_by_ext, Path.extname(path) |> String.trim_leading("."), "application/octet-stream")
  end
end
