defmodule Nexus.S3 do
  @moduledoc """
  A minimal, dependency-free S3 client — AWS Signature V4 over `:httpc`/`:crypto`, path-style
  addressing so it speaks to ANY S3-compatible endpoint (R2, MinIO, Backblaze B2, AWS, …). Just the
  three ops a content-addressed blob store needs: `get/2`, `put/3`, `head/2`. No listing, no ACLs,
  no XML — blobs are immutable (keyed by content hash), so there's nothing to coordinate.

  Location (`bucket`, `prefix`, `endpoint`, `region`) is CONFIG (from the `deploy` block); credentials
  are SECRETS (`WB_S3_ACCESS_KEY_ID` / `WB_S3_SECRET_ACCESS_KEY`, loaded into the nexus at deploy).
  Absent creds → `configured?/0` is false and the caller stays local-only.
  """
  @service "s3"

  @doc "Are S3 credentials present? (else the remote cache tier is simply disabled)"
  def configured?, do: access_key() != nil and secret_key() != nil

  @doc "GET an object → {:ok, body} | {:error, reason} (:not_found for a 404)."
  def get(loc, key), do: request(:get, loc, key, "")

  @doc "PUT bytes → :ok | {:error, reason}."
  def put(loc, key, body) do
    case request(:put, loc, key, body) do
      {:ok, _} -> :ok
      err -> err
    end
  end

  @doc "HEAD → :ok | :not_found | {:error, reason}."
  def head(loc, key) do
    case request(:head, loc, key, "") do
      {:ok, _} -> :ok
      {:error, :not_found} -> :not_found
      err -> err
    end
  end

  # ── request ─────────────────────────────────────────────────────────────────────────────────
  defp request(method, %{endpoint: endpoint, bucket: bucket, prefix: prefix, region: region}, key, body) do
    :inets.start()
    :ssl.start()
    uri = URI.parse(endpoint)
    host = if uri.port in [nil, 80, 443], do: uri.host, else: "#{uri.host}:#{uri.port}"
    full_key = [prefix, key] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("/")
    canonical_path = "/" <> enc_path(bucket <> "/" <> full_key)
    url = "#{endpoint}#{canonical_path}" |> String.to_charlist()

    {amzdate, date} = stamps()
    payload_hash = hex(:crypto.hash(:sha256, body))

    headers =
      sign(method, host, canonical_path, "", payload_hash, amzdate, date, region)
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    http_opts = [ssl: ssl_opts(uri.host), timeout: 30_000]
    do_request(method, url, headers, body, http_opts)
  end

  defp do_request(:put, url, headers, body, http_opts) do
    handle(:httpc.request(:put, {url, headers, ~c"application/octet-stream", body}, http_opts, body_format: :binary))
  end

  defp do_request(method, url, headers, _body, http_opts) do
    handle(:httpc.request(method, {url, headers}, http_opts, body_format: :binary))
  end

  defp handle({:ok, {{_, code, _}, _h, body}}) when code in 200..299, do: {:ok, body}
  defp handle({:ok, {{_, 404, _}, _h, _b}}), do: {:error, :not_found}
  defp handle({:ok, {{_, code, _}, _h, body}}), do: {:error, {:http, code, body}}
  defp handle({:error, reason}), do: {:error, reason}

  # ── SigV4 (generic; validated against AWS's published get-vanilla test vector) ────────────────
  @doc false
  def sign(method, host, canonical_path, query, payload_hash, amzdate, date, region, opts \\ []) do
    akid = opts[:access_key] || access_key()
    secret = opts[:secret_key] || secret_key()
    service = opts[:service] || @service

    signed_headers = "host;x-amz-content-sha256;x-amz-date"

    canonical_headers =
      "host:#{host}\n" <> "x-amz-content-sha256:#{payload_hash}\n" <> "x-amz-date:#{amzdate}\n"

    canonical_request =
      [http_method(method), canonical_path, query, canonical_headers, signed_headers, payload_hash]
      |> Enum.join("\n")

    scope = "#{date}/#{region}/#{service}/aws4_request"

    string_to_sign =
      ["AWS4-HMAC-SHA256", amzdate, scope, hex(:crypto.hash(:sha256, canonical_request))]
      |> Enum.join("\n")

    signature = hex(:crypto.mac(:hmac, :sha256, signing_key(secret, date, region, service), string_to_sign))

    auth =
      "AWS4-HMAC-SHA256 Credential=#{akid}/#{scope}, " <>
        "SignedHeaders=#{signed_headers}, Signature=#{signature}"

    [
      {"host", host},
      {"x-amz-content-sha256", payload_hash},
      {"x-amz-date", amzdate},
      {"Authorization", auth}
    ]
  end

  defp signing_key(secret, date, region, service) do
    ["AWS4" <> secret, date, region, service, "aws4_request"]
    |> Enum.reduce(fn step, key -> :crypto.mac(:hmac, :sha256, key, step) end)
  end

  defp http_method(m), do: m |> Atom.to_string() |> String.upcase()

  # Percent-encode a path, preserving "/". Each segment uses RFC-3986 unreserved + S3-safe set.
  defp enc_path(path) do
    path |> String.split("/") |> Enum.map_join("/", fn seg -> URI.encode(seg, &unreserved?/1) end)
  end

  defp unreserved?(c),
    do: c in ?A..?Z or c in ?a..?z or c in ?0..?9 or c in [?-, ?_, ?., ?~]

  defp stamps do
    now = DateTime.utc_now()
    amzdate = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    date = Calendar.strftime(now, "%Y%m%d")
    {amzdate, date}
  end

  defp ssl_opts(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)
  defp access_key, do: System.get_env("WB_S3_ACCESS_KEY_ID")
  defp secret_key, do: System.get_env("WB_S3_SECRET_ACCESS_KEY")
end
