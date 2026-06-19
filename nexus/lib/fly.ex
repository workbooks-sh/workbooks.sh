defmodule Nexus.Fly do
  @moduledoc """
  A thin client for the Fly Machines API (https://api.machines.dev/v1) — the control-plane's lever
  for provisioning per-tenant nexus machines.

  AUTH: a `Bearer` token from `FLY_API_TOKEN` (a HOST credential, never caller/tenant input). The
  token is added ONLY inside the `:httpc` call — never in `build_request/4`'s pure return, never
  logged. The API host is a fixed constant; it can't be redirected by input. TLS is verified
  (`verify_peer` + pinned SNI) so the token can't be MITM-stolen. JSON here is a genuine network-API
  payload (the legitimate JSON exception).

  `opts[:http]` injects a transport `(method, url, headers, body) -> {:ok,{status,body}} | {:error,_}`
  so tests exercise everything without a network; `opts[:token]` overrides the env token.
  """
  @api_host "https://api.machines.dev/v1"
  @gql_host "https://api.fly.io/graphql"
  @max_body_bytes 8 * 1024 * 1024

  def create_app(name, org, opts \\ []),
    do: request(:post, ["apps"], %{"app_name" => name, "org_slug" => org}, opts)

  def create_machine(app, config, opts \\ []) when is_map(config),
    do: request(:post, ["apps", app, "machines"], %{"config" => config}, opts)

  def get_machine(app, id, opts \\ []), do: request(:get, ["apps", app, "machines", id], nil, opts)
  def start_machine(app, id, opts \\ []), do: machine_action(app, id, "start", opts)
  def stop_machine(app, id, opts \\ []), do: machine_action(app, id, "stop", opts)

  def destroy_machine(app, id, opts \\ []),
    do: request(:delete, ["apps", app, "machines", id <> "?force=true"], nil, opts)

  def delete_app(app, opts \\ []), do: request(:delete, ["apps", app], nil, opts)

  # ── custom-domain certificates (Fly GraphQL — the Machines REST API has no cert surface) ─────────
  # Binds a hostname to a tenant's nexus app: Fly provisions a LetsEncrypt cert and
  # returns the DNS validation target (the record the owner points their domain at).
  @add_cert """
  mutation($appId:ID!,$hostname:String!){addCertificate(appId:$appId,hostname:$hostname){\
  certificate{configured dnsValidationTarget dnsValidationHostname check}}}\
  """
  @check_cert """
  query($appName:String!,$hostname:String!){app(name:$appName){\
  certificate(hostname:$hostname){configured check clientStatus dnsValidationTarget}}}\
  """
  @remove_cert """
  mutation($appId:ID!,$hostname:String!){deleteCertificate(appId:$appId,hostname:$hostname){\
  certificate{hostname}}}\
  """

  def add_certificate(app, hostname, opts \\ []),
    do: graphql(@add_cert, %{"appId" => app, "hostname" => hostname}, opts)

  def check_certificate(app, hostname, opts \\ []),
    do: graphql(@check_cert, %{"appName" => app, "hostname" => hostname}, opts)

  def remove_certificate(app, hostname, opts \\ []),
    do: graphql(@remove_cert, %{"appId" => app, "hostname" => hostname}, opts)

  defp graphql(query, variables, opts) do
    body = %{"query" => query, "variables" => variables}
    headers = [{"accept", "application/json"}, {"content-type", "application/json"}]
    token = Keyword.get(opts, :token) || Nexus.Secrets.get("FLY_API_TOKEN") || ""
    http = Keyword.get(opts, :http, &do_request(&1, &2, &3, &4, token, "api.fly.io"))

    case http.(:post, @gql_host, headers, Jason.encode!(body)) do
      {:ok, {status, resp}} when status in 200..299 -> {:ok, decode(resp)}
      {:ok, {status, resp}} -> {:error, {status, decode(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp machine_action(app, id, action, opts),
    do: request(:post, ["apps", app, "machines", id, action], nil, opts)

  @doc false
  def api_host, do: @api_host

  @doc "Pure request shape (no token, no IO) — exposed so tests can pin host/headers/body."
  def build_request(method, segments, body, _opts \\ []) when is_list(segments) do
    url = @api_host <> "/" <> Enum.join(segments, "/")
    headers = [{"accept", "application/json"}] ++ if(is_map(body), do: [{"content-type", "application/json"}], else: [])
    encoded = if is_map(body), do: Jason.encode!(body), else: ""
    {method, url, headers, encoded}
  end

  @doc false
  def http_options(host \\ "api.machines.dev") do
    [
      timeout: 30_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: to_charlist(host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  defp request(method, segments, body, opts) do
    {method, url, headers, encoded} = build_request(method, segments, body, opts)
    token = Keyword.get(opts, :token) || Nexus.Secrets.get("FLY_API_TOKEN") || ""
    http = Keyword.get(opts, :http, &do_request(&1, &2, &3, &4, token, "api.machines.dev"))

    case http.(method, url, headers, encoded) do
      {:ok, {status, resp}} when status in 200..299 -> {:ok, decode(resp)}
      {:ok, {status, resp}} -> {:error, {status, decode(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Token added HERE only — never in build_request, never logged.
  defp do_request(method, url, headers, body, token, sni) do
    :inets.start()
    :ssl.start()
    headers = [{"authorization", "Bearer " <> token} | headers]
    hh = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    req =
      if method in [:post, :put, :patch, :delete] and body != "",
        do: {to_charlist(url), hh, ~c"application/json", body},
        else: {to_charlist(url), hh}

    case :httpc.request(method, req, http_options(sni), body_format: :binary) do
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
