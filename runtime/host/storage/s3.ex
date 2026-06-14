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
    case obj(tenant, key) do
      {:ok, object} -> (case request("PUT", object, bytes), do: ({:ok, _} -> :ok; e -> e))
      {:error, _} = err -> err
    end
  end

  @impl true
  def get(tenant, key) do
    with {:ok, object} <- obj(tenant, key),
         {:ok, body} <- request("GET", object, "") do
      {:ok, body}
    else
      _ -> :error
    end
  end

  @impl true
  def delete(tenant, key) do
    # Fail-CLOSED: propagate the backend result so the facade only frees quota on a
    # CONFIRMED delete. A 2xx OR a 404 (already gone) = the object is gone → :ok;
    # any other error keeps the ledger row charged.
    case obj(tenant, key) do
      {:error, _} = err ->
        err

      {:ok, object} ->
        case request("DELETE", object, "") do
          {:ok, _} -> :ok
          {:error, "HTTP 404" <> _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  @impl true
  def list(tenant, prefix) do
    case Workbooks.Storage.safe_tenant(tenant) do
      {:error, _} -> []
      {:ok, tenant} -> do_list(tenant, prefix)
    end
  end

  defp do_list(tenant, prefix) do
    full = "#{tenant}/blobs/" <> (if prefix in [nil, ""], do: "", else: prefix)

    case request("GET", "", "", %{"list-type" => "2", "prefix" => full}) do
      {:ok, xml} ->
        Regex.scan(~r/<Key>([^<]+)<\/Key>/, xml)
        |> Enum.map(fn [_, k] -> String.replace_prefix(k, "#{tenant}/blobs/", "") end)

      _ -> []
    end
  end

  # The object path is the tenant-isolation boundary. Validate the tenant as a
  # single opaque segment (defensive — the facade already does, but a presigned URL
  # carries a VALID SIGNATURE, so a raw "../other" tenant here would escape into
  # another prefix). Reuse the facade's canonical guards (DRY).
  defp obj(tenant, key) do
    with {:ok, tenant} <- Workbooks.Storage.safe_tenant(tenant),
         {:ok, key} <- safe_key(key) do
      {:ok, "#{tenant}/blobs/#{key}"}
    end
  end

  # ── Presigned query-string URLs (zero-egress direct browser <-> R2) ───────────
  @default_expiry 900
  @max_expiry 7 * 24 * 3600

  @doc """
  A time-limited SigV4 query-string presigned URL the browser can `PUT` to directly
  (zero proxy). Object path is `<tenant>/blobs/<key>`; the key is scoped so a tenant
  cannot presign outside its own prefix. opts: `:expires_in` (seconds, default 900,
  clamped to [1, 7d]); `:config`/`:now`/`:tenant_scoped` for deterministic tests.
  """
  def presign_put(tenant, key, opts \\ []), do: presign("PUT", tenant, key, opts)

  @doc "As `presign_put/3` but a `GET` URL for direct browser download."
  def presign_get(tenant, key, opts \\ []), do: presign("GET", tenant, key, opts)

  defp presign(method, tenant, key, opts) do
    cfg = Keyword.get(opts, :config) || config()

    cond do
      cfg.endpoint == "" -> {:error, :no_endpoint}
      cfg.key == "" or cfg.secret == "" -> {:error, :no_credentials}
      true ->
        case obj(tenant, key) do
          {:ok, object} -> {:ok, build_presigned_url(method, object, cfg, opts)}
          {:error, _} = err -> err
        end
    end
  end

  # Same key-scoping as the Storage facade — reuse its canonical guard (DRY); the
  # facade returns {:error, :empty_key} for a dot-only/empty key (no crash).
  defp safe_key(key), do: Workbooks.Storage.safe_key(key)

  defp build_presigned_url(method, object, cfg, opts) do
    host = signed_host(cfg.endpoint)
    path = "/" <> cfg.bucket <> "/" <> uri_encode(object, false)
    {amz_date, date} = Keyword.get(opts, :now) || timestamps()
    expires = opts |> Keyword.get(:expires_in, @default_expiry) |> clamp_expiry()

    scope = "#{date}/#{cfg.region}/#{@service}/aws4_request"

    # For a metered PUT, SIGN the Content-Length header so R2/S3 rejects an upload
    # of a different size than the bytes we reserved against the quota.
    content_length = if method == "PUT", do: Keyword.get(opts, :content_length), else: nil

    {extra_headers, signed_headers} =
      if is_integer(content_length) and content_length >= 0,
        do: {[{"content-length", Integer.to_string(content_length)}], "content-length;host"},
        else: {[], "host"}

    # Canonical query params MUST be sorted; the signature itself is NOT a param.
    base_query = [
      {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
      {"X-Amz-Credential", "#{cfg.key}/#{scope}"},
      {"X-Amz-Date", amz_date},
      {"X-Amz-Expires", Integer.to_string(expires)},
      {"X-Amz-SignedHeaders", signed_headers}
    ]

    canonical_query =
      base_query
      |> Enum.sort()
      |> Enum.map_join("&", fn {k, v} -> "#{uri_encode(k, true)}=#{uri_encode(v, true)}" end)

    # Canonical headers MUST be sorted by lowercase name; content-length sorts first.
    canonical_headers =
      ([{"host", host} | extra_headers])
      |> Enum.sort()
      |> Enum.map_join("", fn {k, v} -> "#{k}:#{v}\n" end)

    canonical_request =
      [method, path, canonical_query, canonical_headers, signed_headers, "UNSIGNED-PAYLOAD"]
      |> Enum.join("\n")

    string_to_sign =
      ["AWS4-HMAC-SHA256", amz_date, scope, hex(sha256(canonical_request))] |> Enum.join("\n")

    signature = hex(hmac(signing_key(cfg.secret, date, cfg.region), string_to_sign))

    cfg.endpoint <> path <> "?" <> canonical_query <> "&X-Amz-Signature=" <> signature
  end

  defp clamp_expiry(n) when is_integer(n) and n >= 1, do: min(n, @max_expiry)
  defp clamp_expiry(_), do: @default_expiry

  # ── SigV4-signed request ──────────────────────────────────────────────────────
  # The SignedHeaders `host` value MUST include a non-default port or signatures
  # fail on MinIO/custom-port endpoints. Shared by presign + request/4 (DRY).
  defp signed_host(endpoint) do
    u = URI.parse(endpoint)
    if u.port in [80, 443, nil], do: u.host, else: "#{u.host}:#{u.port}"
  end

  defp request(method, key, body, query \\ %{}) do
    cfg = config()
    host = signed_host(cfg.endpoint)
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
