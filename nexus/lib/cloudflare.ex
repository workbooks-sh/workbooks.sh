defmodule Nexus.Cloudflare do
  @moduledoc """
  Cloudflare-for-SaaS **custom hostnames** — the cheap, scale path for attaching customer domains. A
  customer points one CNAME at our fallback origin; we register the hostname here, Cloudflare issues +
  auto-renews a per-hostname TLS cert and terminates at its edge, proxying to our Fly origin. No reverse
  proxy of ours, no Let's Encrypt rate limits, no per-app Fly cert. First 100 hostnames free, then
  ~$0.10/hostname/mo.

  **Generic, no-op-safe.** With no API token (`configured?/0` false) every call returns `{:skip, reason}`
  — the runtime falls back to the per-app Fly-cert domain path (`Nexus.ControlPlane.Domain`). THE LINE:
  neutral Cloudflare plumbing; the SaaS zone id + fallback origin are the deployer's `.work` config
  (`Nexus.Config.cf_saas_zone/0`, `cf_custom_hostname_origin/0`), not baked in.

  AUTH: a scoped `Bearer` token from `CLOUDFLARE_API_TOKEN` (Zone : SSL and Certificates : Edit, scoped
  to the SaaS zone) — a HOST secret via `Nexus.Secrets`, added only inside the `:httpc` call, never
  logged. The API host is a fixed constant; TLS is verified + SNI-pinned. JSON is a genuine network
  payload (the legitimate exception). `opts[:http]` injects a transport for tests; `opts[:token]`
  overrides the env token; `opts[:zone]` overrides the configured zone.

  All calls return `{:ok, result} | {:skip, reason} | {:error, reason}` where `result` is the CF
  response's `result` object (or `errors` on a CF-level failure).
  """
  @api "https://api.cloudflare.com/client/v4"
  @max_body_bytes 1024 * 1024

  @doc "Is a Cloudflare API token present? Gates every call (off ⇒ fall back to the Fly-cert path)."
  def configured?, do: Nexus.Secrets.has?("CLOUDFLARE_API_TOKEN")

  @doc "Both a token AND a SaaS zone are needed to register custom hostnames."
  def saas_ready?(opts \\ []), do: configured?() and not is_nil(zone(opts))

  @doc """
  Register a custom hostname on the SaaS zone. `ssl_method` is `"http"` (default), `"txt"`, or `"cname"`
  domain-control validation. Returns the CF hostname object (carries `id`, `ssl.status`, and the DCV
  records the customer may need to publish).
  """
  def create_custom_hostname(hostname, opts \\ []) do
    method = opts[:ssl_method] || "http"

    body = %{
      "hostname" => hostname,
      "ssl" => %{"method" => method, "type" => "dv", "settings" => %{"min_tls_version" => "1.2"}}
    }

    request(:post, ["zones", zone(opts), "custom_hostnames"], body, opts)
  end

  @doc "Fetch a custom hostname by id — poll `result.ssl.status` until `active`."
  def get_custom_hostname(id, opts \\ []),
    do: request(:get, ["zones", zone(opts), "custom_hostnames", id], nil, opts)

  @doc "Delete a custom hostname (drops its cert)."
  def delete_custom_hostname(id, opts \\ []),
    do: request(:delete, ["zones", zone(opts), "custom_hostnames", id], nil, opts)

  defp zone(opts), do: opts[:zone] || Nexus.Config.cf_saas_zone()

  # ── request ────────────────────────────────────────────────────────────────────────────────────
  defp request(method, segments, body, opts) do
    token = opts[:token] || Nexus.Secrets.get("CLOUDFLARE_API_TOKEN")

    cond do
      is_nil(token) or token == "" ->
        {:skip, "cloudflare api token not configured"}

      is_nil(zone(opts)) ->
        {:skip, "cloudflare saas zone not configured"}

      true ->
        url = @api <> "/" <> Enum.join(Enum.map(segments, &to_string/1), "/")
        http = Keyword.get(opts, :http, &do_request(&1, &2, &3, &4, token))
        headers = [{"accept", "application/json"}] ++ if(is_map(body), do: [{"content-type", "application/json"}], else: [])
        encoded = if is_map(body), do: Jason.encode!(body), else: ""

        case http.(method, url, headers, encoded) do
          {:ok, {status, resp}} when status in 200..299 ->
            m = decode(resp)
            if m["success"] == false, do: {:error, {:cf_error, m["errors"]}}, else: {:ok, m["result"]}

          {:ok, {status, resp}} ->
            m = decode(resp)
            {:error, {:cf_http, status, m["errors"] || m}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Token added HERE only — never in the pure request shape, never logged.
  defp do_request(method, url, headers, body, token) do
    :inets.start()
    :ssl.start()
    headers = [{"authorization", "Bearer " <> token} | headers]
    hh = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    req =
      if method in [:post, :put, :patch] and body != "",
        do: {to_charlist(url), hh, ~c"application/json", body},
        else: {to_charlist(url), hh}

    o = [
      timeout: 15_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: ~c"api.cloudflare.com",
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(method, req, o, body_format: :binary) do
      {:ok, {{_, code, _}, _h, resp}} -> {:ok, {code, cap(resp)}}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp cap(bin) when is_binary(bin) and byte_size(bin) > @max_body_bytes, do: binary_part(bin, 0, @max_body_bytes)
  defp cap(bin), do: bin

  defp decode(""), do: %{}
  defp decode(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, v} -> v
      _ -> %{}
    end
  end

  defp decode(other), do: other
end
