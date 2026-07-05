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

  AUTH: a scoped `Bearer` token from `CLOUDFLARE_API_TOKEN` — a HOST secret via `Nexus.Secrets`, added
  only inside the `:httpc` call, never logged. Scopes: `Zone : SSL and Certificates : Edit` (custom
  hostnames) plus `Zone : DNS : Edit` + `Zone : Email Routing : Edit` for the DNS/agent-email seam
  below. The value may equally be an **OAuth access token** carrying the same scopes (`dns.write` /
  `zone.read` / `email-routing.write`) — the module is token-source-agnostic: whatever resolves through
  `Nexus.Secrets` (or `opts[:token]`) is used verbatim. The API host is a fixed constant; TLS is
  verified + SNI-pinned. `opts[:http]` injects a transport for tests; `opts[:token]` overrides the env
  token; `opts[:zone]` overrides the configured zone; `opts[:query]` (map) → URL query params.

  DNS + Email Routing (the zone-management seam behind agent email `agents.<domain>` and custom
  domains): `{list,create,update,delete,upsert}_dns_record(s)` write MX·SPF·DKIM·DMARC + verification
  records idempotently; `enable_email_routing/1` + `set_email_catch_all/2` wire inbound mail →
  a CF Email Worker → the Nexus ingress. DNS calls default their zone to `Nexus.Config.cf_dns_zone/0`.

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

  # ── DNS records ──────────────────────────────────────────────────────────────────────────────────
  # The zone-management seam behind agent email (write relay/provider MX·SPF·DKIM·DMARC + verification)
  # and custom domains (CNAME). Zone defaults to `Nexus.Config.cf_dns_zone/0` (the operator's primary
  # zone, e.g. workbooks.sh), overridable per call with `opts[:zone]`.

  @doc """
  List DNS records in the zone. `opts[:filter]` (map) becomes CF query params, e.g.
  `%{"type" => "MX", "name" => "agents.workbooks.sh"}`. Returns `{:ok, [record, ...]}`.
  """
  def list_dns_records(opts \\ []) do
    opts = dns_opts(opts)
    request(:get, ["zones", zone(opts), "dns_records"], nil, Keyword.put(opts, :query, opts[:filter] || %{}))
  end

  @doc """
  Create a DNS record. `record` needs `"type"`, `"name"`, and `"content"` (or provider-style `"value"`,
  which is mapped to `content`); optional `"priority"` (MX), `"ttl"` (defaults to 1 = automatic),
  `"proxied"`. Returns the CF record object (carries `id`).
  """
  def create_dns_record(record, opts \\ []) when is_map(record) do
    opts = dns_opts(opts)
    request(:post, ["zones", zone(opts), "dns_records"], normalize_record(record), opts)
  end

  @doc "Replace a DNS record by id (PUT). `record` same shape as `create_dns_record/2`."
  def update_dns_record(id, record, opts \\ []) when is_map(record) do
    opts = dns_opts(opts)

    with {:ok, id} <- safe_id(id),
         do: request(:put, ["zones", zone(opts), "dns_records", id], normalize_record(record), opts)
  end

  @doc "Delete a DNS record by id."
  def delete_dns_record(id, opts \\ []) do
    opts = dns_opts(opts)
    with {:ok, id} <- safe_id(id), do: request(:delete, ["zones", zone(opts), "dns_records", id], nil, opts)
  end

  @doc """
  Idempotently ensure a record with the given content exists. Matches an existing record by
  (`type`, `name`) — updates it in place if found, creates it otherwise. The provisioning primitive:
  re-running a domain setup never duplicates records. Returns `{:ok, record}`.
  """
  def upsert_dns_record(record, opts \\ []) when is_map(record) do
    r = normalize_record(record)

    case list_dns_records(Keyword.put(opts, :filter, %{"type" => r["type"], "name" => r["name"]})) do
      {:ok, [%{"id" => id} | _]} -> update_dns_record(id, r, opts)
      {:ok, _} -> create_dns_record(r, opts)
      other -> other
    end
  end

  @doc """
  Upsert a batch of records (the shape a provider's domain-verification response returns — each
  `%{"type"=>_, "name"=>_, "content"|"value"=>_, "priority"=>_}`). Returns `{:ok, [record, ...]}` on
  full success, or the first `{:error, _}` / `{:skip, _}` encountered (stops at the first failure).
  """
  def upsert_dns_records(records, opts \\ []) when is_list(records) do
    records
    |> Enum.reduce_while({:ok, []}, fn rec, {:ok, acc} ->
      case upsert_dns_record(rec, opts) do
        {:ok, r} -> {:cont, {:ok, [r | acc]}}
        other -> {:halt, other}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  # ── Email Routing (inbound: MX → CF → catch-all → Email Worker → Nexus ingress) ──────────────────

  @doc "Enable Email Routing on the zone (CF provisions the MX + verification TXT). POST .../email/routing/enable."
  def enable_email_routing(opts \\ []) do
    opts = dns_opts(opts)
    request(:post, ["zones", zone(opts), "email", "routing", "enable"], %{}, opts)
  end

  @doc "Email Routing settings/status for the zone (poll `status` → `\"ready\"`). GET .../email/routing."
  def email_routing_settings(opts \\ []) do
    opts = dns_opts(opts)
    request(:get, ["zones", zone(opts), "email", "routing"], nil, opts)
  end

  @doc """
  Point the catch-all rule at a deployed Email Worker so every inbound message is handed to it (the
  Worker forwards the raw MIME to the Nexus `/cloud/email/inbound` ingress). PUT
  .../email/routing/rules/catch_all. Returns the rule object.
  """
  def set_email_catch_all(worker_name, opts \\ []) when is_binary(worker_name) do
    opts = dns_opts(opts)

    body = %{
      "name" => "catch-all → " <> worker_name,
      "enabled" => true,
      "matchers" => [%{"type" => "all"}],
      "actions" => [%{"type" => "worker", "value" => [worker_name]}]
    }

    request(:put, ["zones", zone(opts), "email", "routing", "rules", "catch_all"], body, opts)
  end

  defp dns_opts(opts), do: Keyword.put_new(opts, :zone, Nexus.Config.cf_dns_zone())

  # Whitelist the keys CF's DNS API accepts (an unknown key like a provider's `status`/`value` would be
  # rejected). Map provider-style `"value"` → CF `"content"`, default ttl to automatic (1), drop nils.
  @dns_keys ~w(type name content priority ttl proxied comment)
  defp normalize_record(r) do
    m = Map.new(r, fn {k, v} -> {to_string(k), v} end)
    m = if m["content"] in [nil, ""] and m["value"], do: Map.put(m, "content", m["value"]), else: m

    m
    |> Map.put_new("ttl", 1)
    |> Map.take(@dns_keys)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # A CF record id path segment: a single opaque token (CF ids are 32-hex). Fails closed so a crafted
  # "../rules" can never escape into a sibling resource.
  defp safe_id(s) when is_binary(s) and s != "" do
    if String.match?(s, ~r/^[A-Za-z0-9_\-]+$/), do: {:ok, s}, else: {:error, :invalid_id}
  end

  defp safe_id(_), do: {:error, :invalid_id}

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
        url = @api <> "/" <> Enum.join(Enum.map(segments, &to_string/1), "/") <> query_string(opts[:query])
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

  defp query_string(q) when is_map(q) and map_size(q) > 0, do: "?" <> URI.encode_query(q)
  defp query_string(_), do: ""

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
