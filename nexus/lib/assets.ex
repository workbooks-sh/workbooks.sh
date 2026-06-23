defmodule Nexus.Assets do
  @moduledoc """
  Generated-asset blob store — the home for bytes an agent PRODUCES (a generated image / clip / audio),
  as opposed to `Nexus.Store` (typed rows) or the git-backed workspace tree (authored source).

  Bytes land under `<data_dir>/assets/<tenant>/<id>.<ext>` (the persistent volume) and are served
  read-only at `/assets/<tenant>/<id>.<ext>` by `Nexus.Server`. Generic mechanism — no Workbooks
  business — so any workbook that generates a binary uses the same store + URL.
  """

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
       url: "/assets/#{safe(tenant)}/#{name}",
       content_type: content_type,
       bytes: byte_size(bytes)
     }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "Read a stored asset back: `{:ok, bytes, content_type}` or `:error`. `name` is basename-sanitized."
  def read(tenant, name) do
    path = Path.join(dir(tenant), Path.basename(to_string(name)))

    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes, content_type_for(path)}
      _ -> :error
    end
  end

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
