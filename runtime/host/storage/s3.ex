defmodule Workbooks.Storage.S3 do
  @moduledoc """
  Object-store blob adapter — AWS S3 AND Cloudflare R2 (R2 is S3-compatible, so
  ONE adapter serves both; the difference is purely config). Selected by
  `WB_STORAGE=s3` (or `r2`). SigV4 is hand-rolled on `:crypto` + `:httpc` — no new
  dependency. Config (Fly secrets):

    WB_S3_ENDPOINT  https://s3.us-east-1.amazonaws.com
                    https://<account>.r2.cloudflarestorage.com   (R2)
    WB_S3_BUCKET    bucket name
    WB_S3_KEY / WB_S3_SECRET   access key id / secret
    WB_S3_REGION    us-east-1 (S3) | auto (R2, default)

  Tenant isolation is the key prefix (`<tenant>/blobs/<key>`) — identical scoping
  to the Local adapter, enforced above the backend. See docs/DEPLOY-KIT-STORAGE.org.
  """
  @behaviour Workbooks.Storage

  @service "s3"

  @impl true
  def put(tenant, key, bytes) do
    case request("PUT", obj(tenant, key), bytes), do: ({:ok, _} -> :ok; e -> e)
  end

  @impl true
  def get(tenant, key) do
    case request("GET", obj(tenant, key), "") do
      {:ok, body} -> {:ok, body}
      _ -> :error
    end
  end

  @impl true
  def delete(tenant, key) do
    request("DELETE", obj(tenant, key), "")
    :ok
  end

  @impl true
  def list(tenant, prefix) do
    full = "#{tenant}/blobs/" <> (if prefix in [nil, ""], do: "", else: prefix)

    case request("GET", "", "", %{"list-type" => "2", "prefix" => full}) do
      {:ok, xml} ->
        Regex.scan(~r/<Key>([^<]+)<\/Key>/, xml)
        |> Enum.map(fn [_, k] -> String.replace_prefix(k, "#{tenant}/blobs/", "") end)

      _ -> []
    end
  end

  defp obj(tenant, key), do: "#{tenant}/blobs/#{key}"

  # ── SigV4-signed request ──────────────────────────────────────────────────────
  defp request(method, key, body, query \\ %{}) do
    cfg = config()
    host = URI.parse(cfg.endpoint).host
    path = "/" <> cfg.bucket <> if(key == "", do: "", else: "/" <> uri_encode(key, false))
    {amz_date, date} = timestamps()
    payload_hash = hex(sha256(body))

    canonical_query =
      query |> Enum.sort() |> Enum.map_join("&", fn {k, v} -> "#{uri_encode(k, true)}=#{uri_encode(v, true)}" end)

    headers = %{
      "host" => host,
      "x-amz-content-sha256" => payload_hash,
      "x-amz-date" => amz_date
    }

    signed_headers = headers |> Map.keys() |> Enum.sort() |> Enum.join(";")
    canonical_headers = headers |> Enum.sort() |> Enum.map_join("", fn {k, v} -> "#{k}:#{v}\n" end)

    canonical_request =
      [method, path, canonical_query, canonical_headers, signed_headers, payload_hash] |> Enum.join("\n")

    scope = "#{date}/#{cfg.region}/#{@service}/aws4_request"
    string_to_sign = ["AWS4-HMAC-SHA256", amz_date, scope, hex(sha256(canonical_request))] |> Enum.join("\n")
    signature = hex(hmac(signing_key(cfg.secret, date, cfg.region), string_to_sign))

    auth =
      "AWS4-HMAC-SHA256 Credential=#{cfg.key}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"

    url = cfg.endpoint <> path <> if(canonical_query == "", do: "", else: "?" <> canonical_query)

    http_headers =
      [{~c"authorization", to_charlist(auth)} | Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)]

    do_http(method, url, http_headers, body)
  end

  defp do_http(method, url, headers, body) do
    :inets.start()
    :ssl.start()
    m = method |> String.downcase() |> String.to_atom()

    req =
      if method in ["PUT", "POST"],
        do: {to_charlist(url), headers, ~c"application/octet-stream", body},
        else: {to_charlist(url), headers}

    case :httpc.request(m, req, [timeout: 30_000], body_format: :binary) do
      {:ok, {{_, code, _}, _, resp}} when code in 200..299 -> {:ok, resp}
      {:ok, {{_, code, _}, _, resp}} -> {:error, "HTTP #{code}: #{String.slice(resp, 0, 200)}"}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  # ── SigV4 primitives (public for the test vector) ────────────────────────────
  @doc false
  def signing_key(secret, date, region, service \\ @service) do
    ("AWS4" <> secret)
    |> hmac(date)
    |> hmac(region)
    |> hmac(service)
    |> hmac("aws4_request")
  end

  defp sha256(data), do: :crypto.hash(:sha256, data)
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex(bin), do: Base.encode16(bin, case: :lower)

  # RFC 3986 encoding; `path?` keeps "/" unescaped (object keys are paths).
  defp uri_encode(str, query?) do
    keep = if query?, do: ~c"-_.~", else: ~c"-_.~/"

    str
    |> to_string()
    |> :binary.bin_to_list()
    |> Enum.map_join(fn c ->
      if (c in ?A..?Z) or (c in ?a..?z) or (c in ?0..?9) or c in keep,
        do: <<c>>,
        else: "%" <> (Base.encode16(<<c>>, case: :upper))
    end)
  end

  defp timestamps do
    now = DateTime.utc_now()
    amz = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    {amz, String.slice(amz, 0, 8)}
  end

  defp config do
    %{
      endpoint: String.trim_trailing(System.get_env("WB_S3_ENDPOINT", ""), "/"),
      bucket: System.get_env("WB_S3_BUCKET", ""),
      key: System.get_env("WB_S3_KEY", ""),
      secret: System.get_env("WB_S3_SECRET", ""),
      region: System.get_env("WB_S3_REGION", "auto")
    }
  end
end
