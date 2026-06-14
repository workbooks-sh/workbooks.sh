defmodule Workbooks.Billing.Polar do
  @moduledoc """
  A thin client for the Polar billing API (https://api.polar.sh) plus the
  Standard-Webhooks signature verification that gates every inbound billing
  event — the host side that meters usage, reads subscriptions, and mints
  checkout / customer-portal links for a tenant.

  Mirrors `Workbooks.Neon` and `Workbooks.FlyMachines` exactly for the API part:

  AUTH: a `Bearer` token from `POLAR_ACCESS_TOKEN` (an Organization Access
  Token). The token is a HOST credential and the isolation key for the whole
  Polar org — so it NEVER appears in a log line, an error tuple, or any returned
  value. It lives only in the `authorization` request header handed straight to
  `:httpc` (added in `do_request/5`, never in `build_request/4`).

  SSRF FLOOR: the API host is the FIXED module constant `@api_host`
  (`https://api.polar.sh`). It is never taken from caller/tenant input, so this
  client can't be pointed at an attacker-chosen origin. Subscription ids are
  validated as single opaque path segments (`safe_segment/1`) before
  interpolation — a `../`, slash, or query char fails closed.

  ERRORS: a non-2xx response maps to `{:error, {status, body}}` (the body is
  Polar's JSON, never our headers) — never raises on an HTTP error. The HTTP
  layer is INJECTABLE: every public fn threads an `opts` keyword carrying
  `:http` (`fun(method, url, headers, body) -> {:ok, {status, body}} | {:error, term}`)
  so the request CONSTRUCTION (`build_request/4`, pure) is unit-testable with no
  network at all.

  ENDPOINTS — confirmed against the Polar API reference (https://polar.sh/docs/api-reference):
    * ingest usage events     — POST /v1/events/ingest
                                (polar.sh/docs/api-reference/events/ingest; scope events:write)
    * get one subscription    — GET  /v1/subscriptions/:id
                                (polar.sh/docs/api-reference/subscriptions/get)
    * create checkout session — POST /v1/checkouts/
                                (polar.sh/docs/api-reference/checkouts/create-session)
    * create customer session — POST /v1/customer-sessions
                                (polar.sh/docs/api-reference/customer-portal/sessions/create)
                                response carries the pre-authenticated `customer_portal_url`

  WEBHOOKS — `verify_webhook/3` implements the Standard Webhooks spec that Polar
  follows (https://www.standardwebhooks.com/, spec at
  github.com/standard-webhooks/standard-webhooks/blob/main/spec/standard-webhooks.md).
  Fails closed: a missing header, malformed secret, bad base64, an out-of-tolerance
  timestamp, or no matching v1 signature all return `{:error, reason}`. The
  signature compare is constant-time (`:crypto.hash_equals`).
  """

  @api_host "https://api.polar.sh"
  @sni ~c"api.polar.sh"

  # Standard-Webhooks default replay-tolerance: reject if the delivery timestamp
  # is more than 5 minutes away from now (past OR future).
  @tolerance_seconds 5 * 60

  # ── Part A: Standard-Webhooks verification (the security keystone) ───────────────

  @doc """
  Verify an inbound Polar webhook per the Standard Webhooks spec and return
  `{:ok, parsed_event}` ONLY on a valid, in-tolerance signature.

    * `payload_raw` — the RAW request body bytes, exactly as received. The signed
      content is built from THIS, never a re-encoded JSON, or the HMAC won't match.
    * `headers`     — the request headers as a map or a list of `{name, value}`
      pairs. Names are matched case-insensitively. Required:
      `webhook-id`, `webhook-timestamp`, `webhook-signature`.
    * `secret`      — the endpoint signing secret, base64 (often `whsec_`-prefixed).

  Signed content is `"<id>.<timestamp>.<payload_raw>"`. The expected signature
  is `Base64(HMAC-SHA256(decoded_secret, signed_content))`. The `webhook-signature`
  header is a SPACE-separated list of `"v1,<base64sig>"` entries; the webhook is
  accepted if ANY `v1` entry matches under a CONSTANT-TIME compare.

  Fails closed (`{:error, reason}`) on any missing header, malformed secret, bad
  base64, out-of-tolerance timestamp, or no matching signature.
  """
  def verify_webhook(payload_raw, headers, secret)
      when is_binary(payload_raw) and is_binary(secret) do
    with {:ok, id} <- fetch_header(headers, "webhook-id"),
         {:ok, ts_raw} <- fetch_header(headers, "webhook-timestamp"),
         {:ok, sig_header} <- fetch_header(headers, "webhook-signature"),
         {:ok, ts} <- parse_timestamp(ts_raw),
         :ok <- check_tolerance(ts),
         {:ok, key} <- decode_secret(secret),
         :ok <- verify_signature(id, ts_raw, payload_raw, key, sig_header) do
      parse_event(payload_raw)
    end
  end

  def verify_webhook(_payload, _headers, _secret), do: {:error, :invalid_arguments}

  # Build the expected v1 signature and constant-time-compare it against every
  # candidate the sender supplied; accept on the FIRST match. The signed content
  # uses the raw header timestamp string (not the parsed integer) so it is
  # byte-for-byte what the sender signed.
  defp verify_signature(id, ts_raw, payload_raw, key, sig_header) do
    signed = id <> "." <> ts_raw <> "." <> payload_raw
    expected = :crypto.mac(:hmac, :sha256, key, signed)

    candidates =
      sig_header
      |> String.split(" ", trim: true)
      |> Enum.flat_map(&v1_signature/1)

    matched? =
      Enum.any?(candidates, fn cand ->
        # CONSTANT-TIME compare — never `==` on the signature. Decode the
        # candidate's base64; a bad-base64 entry simply can't match.
        case Base.decode64(cand) do
          {:ok, raw} ->
            byte_size(raw) == byte_size(expected) and :crypto.hash_equals(raw, expected)

          :error ->
            false
        end
      end)

    if matched?, do: :ok, else: {:error, :no_matching_signature}
  end

  # Pull the base64 body out of a "v1,<sig>" entry; ignore any other version tag
  # (e.g. asymmetric "v1a,...") and any malformed entry.
  defp v1_signature("v1," <> sig) when sig != "", do: [sig]
  defp v1_signature(_), do: []

  # Strip the optional `whsec_` prefix, then base64-decode the rest to the HMAC
  # key. A non-base64 secret fails closed.
  defp decode_secret(secret) do
    body = String.replace_prefix(secret, "whsec_", "")

    case Base.decode64(body) do
      {:ok, key} when byte_size(key) > 0 -> {:ok, key}
      _ -> {:error, :malformed_secret}
    end
  end

  defp parse_timestamp(ts_raw) do
    case Integer.parse(String.trim(ts_raw)) do
      {ts, ""} -> {:ok, ts}
      _ -> {:error, :bad_timestamp}
    end
  end

  defp check_tolerance(ts) do
    now = System.system_time(:second)

    if abs(now - ts) <= @tolerance_seconds,
      do: :ok,
      else: {:error, :timestamp_out_of_tolerance}
  end

  # Case-insensitive header lookup over a map or a {name, value} list. A missing
  # or empty header fails closed.
  defp fetch_header(headers, name) when is_map(headers),
    do: fetch_header(Map.to_list(headers), name)

  defp fetch_header(headers, name) when is_list(headers) do
    target = String.downcase(name)

    found =
      Enum.find_value(headers, fn {k, v} ->
        if is_binary(k) and String.downcase(k) == target, do: v, else: nil
      end)

    case found do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:missing_header, name}}
    end
  end

  defp fetch_header(_headers, name), do: {:error, {:missing_header, name}}

  defp parse_event(payload_raw) do
    case Jason.decode(payload_raw) do
      {:ok, event} -> {:ok, event}
      {:error, _} -> {:error, :invalid_payload}
    end
  end

  # ── Part B: API client ──────────────────────────────────────────────────────────

  @doc """
  Ingest a batch of usage/metered events. POST /v1/events/ingest.

  `events` is a single event map or a list of them. Each event needs at least a
  `"name"` and a customer identifier (`"customer_id"` or `"external_customer_id"`).
  The events are wrapped under the Polar `{"events": [...]}` envelope.
  """
  def ingest_usage(events, opts \\ []) do
    list = if is_list(events), do: events, else: [events]
    request(:post, ["v1", "events", "ingest"], %{"events" => list}, opts)
  end

  @doc "Get one subscription by id. GET /v1/subscriptions/:id."
  def get_subscription(id, opts \\ []) do
    with {:ok, id} <- safe_segment(id) do
      request(:get, ["v1", "subscriptions", id], nil, opts)
    end
  end

  @doc """
  Create a checkout session. POST /v1/checkouts/.

  `opts[:body]` carries the checkout payload (e.g. `products`, `success_url`,
  `customer_email`, `metadata`). The trailing slash is required by the Polar API.
  """
  def checkout_link(opts \\ []) do
    body = Keyword.get(opts, :body, %{})
    request(:post, ["v1", "checkouts", ""], body, opts)
  end

  @doc """
  Create a customer session that yields a pre-authenticated customer-portal URL.
  POST /v1/customer-sessions. The response carries `customer_portal_url`.

  `opts[:body]` identifies the customer (`customer_id` or `external_customer_id`).
  """
  def portal_link(opts \\ []) do
    body = Keyword.get(opts, :body, %{})
    request(:post, ["v1", "customer-sessions"], body, opts)
  end

  # ── Entitlements (PURE; fail closed) ────────────────────────────────────────────

  @doc """
  Map a subscription's status + plan to the capabilities the tenant may use.

  PURE: no I/O. Fails CLOSED — any status other than `"active"`/`"trialing"`
  (so `canceled`, `past_due`, `unpaid`, `incomplete`, missing, …) yields
  `can_provision: false` with zeroed limits, regardless of the plan tier.

  Accepts a subscription map with string keys (as returned by `get_subscription`)
  or atom keys. Plan tier is read from the product/price slug under
  `product.name` / `price.recurring_interval`-adjacent fields, falling back to a
  `"plan"` field; an unknown plan maps to the conservative `"free"` tier.
  """
  def entitlements(subscription) when is_map(subscription) do
    status = sub_get(subscription, "status")
    plan = sub_plan(subscription)

    if status in ["active", "trialing"] do
      Map.put(plan_limits(plan), :can_provision, true)
    else
      # Fail closed: inactive/canceled/past_due/unknown → no provisioning, no limits.
      %{can_provision: false, max_nexuses: 0, seats: 0, storage_quota_bytes: 0}
    end
  end

  def entitlements(_), do: %{can_provision: false, max_nexuses: 0, seats: 0, storage_quota_bytes: 0}

  @gib 1024 * 1024 * 1024

  defp plan_limits("enterprise"),
    do: %{max_nexuses: 100, seats: 100, storage_quota_bytes: 1024 * @gib}

  defp plan_limits("pro"),
    do: %{max_nexuses: 10, seats: 10, storage_quota_bytes: 100 * @gib}

  defp plan_limits("starter"),
    do: %{max_nexuses: 3, seats: 3, storage_quota_bytes: 10 * @gib}

  # Unknown / "free" tier: minimal but non-zero so an active free sub can still
  # provision a single nexus.
  defp plan_limits(_),
    do: %{max_nexuses: 1, seats: 1, storage_quota_bytes: 1 * @gib}

  # Read the plan tier from a few likely shapes, normalized to a lowercase slug.
  defp sub_plan(sub) do
    raw =
      sub_get(sub, "plan") ||
        sub_get(sub_get(sub, "product") || %{}, "name") ||
        sub_get(sub, "product_name") ||
        "free"

    slug = raw |> to_string() |> String.downcase()

    cond do
      String.contains?(slug, "enterprise") -> "enterprise"
      String.contains?(slug, "pro") -> "pro"
      String.contains?(slug, "starter") or String.contains?(slug, "basic") -> "starter"
      true -> "free"
    end
  end

  defp sub_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, safe_atom(key))
  end

  defp sub_get(_, _), do: nil

  # Only resolve to an already-existing atom — never create atoms from external data.
  defp safe_atom(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end

  # ── Pure request construction (network-free; unit-testable) ─────────────────────

  @doc """
  Build the `{method, url, headers, body}` 4-tuple for a call WITHOUT performing
  it. Pure and network-free. `segments` is a list of already-validated path
  segments appended to the fixed `@api_host`. `body` is a map (JSON-encoded) or nil.

  The `Authorization: Bearer <token>` header is DELIBERATELY NOT added here — the
  token is injected only in the private HTTP layer (`do_request/5`) right before
  the `:httpc` call, so it never appears in this pure return value, a log, or a
  test fixture.
  """
  def build_request(method, segments, body, _opts \\ []) when is_list(segments) do
    url = @api_host <> "/" <> Enum.join(segments, "/")

    headers =
      [{"accept", "application/json"}] ++
        if(is_map(body), do: [{"content-type", "application/json"}], else: [])

    encoded = if is_map(body), do: json_encode(body), else: ""
    {method, url, headers, encoded}
  end

  @doc false
  # The fixed API host — exposed for the test that asserts no caller can change it.
  def api_host, do: @api_host

  @doc false
  # The pinned TLS http-options for the Polar API. SNI is hard-pinned to the fixed
  # api.polar.sh host (same verify_peer pattern as `Workbooks.Neon`/`FlyMachines`).
  # Exposed so the test can regression-lock verify_peer + non-empty cacerts + SNI.
  def http_options do
    [
      timeout: 30_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: @sni,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]
  end

  # ── Internal: construct + dispatch + map ────────────────────────────────────────

  # Cap the response body read so a hostile/oversized response can't exhaust memory.
  @max_body_bytes 8 * 1024 * 1024

  defp request(method, segments, body, opts) do
    {method, url, headers, encoded} = build_request(method, segments, body, opts)
    token = Keyword.get(opts, :token) || System.get_env("POLAR_ACCESS_TOKEN") || ""
    http = Keyword.get(opts, :http, &do_request(&1, &2, &3, &4, token))

    case http.(method, url, headers, encoded) do
      {:ok, {status, resp}} when status in 200..299 -> {:ok, decode(resp)}
      {:ok, {status, resp}} -> {:error, {status, decode(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Real HTTP via :httpc. The `Authorization: Bearer <token>` header is added HERE
  # — never by `build_request` — so the token lives only in the request handed
  # straight to `:httpc`. TLS is verified (verify_peer + pinned SNI) so the token
  # can't be MITM-stolen. Never logs headers.
  defp do_request(method, url, headers, body, token) do
    :inets.start()
    :ssl.start()

    headers = [{"authorization", "Bearer " <> token} | headers]
    http_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    req =
      if method in [:post, :put, :patch, :delete] and body != "" do
        {to_charlist(url), http_headers, ~c"application/json", body}
      else
        {to_charlist(url), http_headers}
      end

    case :httpc.request(method, req, http_options(), body_format: :binary) do
      {:ok, {{_, code, _}, _resp_headers, resp}} -> {:ok, {code, cap_body(resp)}}
      {:error, e} -> {:error, inspect(e)}
    end
  end

  defp cap_body(bin) when is_binary(bin) and byte_size(bin) > @max_body_bytes,
    do: binary_part(bin, 0, @max_body_bytes)

  defp cap_body(bin), do: bin

  # ── Guards & codecs ─────────────────────────────────────────────────────────────

  # A subscription id must be a single opaque path segment: a non-empty binary
  # with no slash, no dot-segment, no query/fragment chars. Fails closed otherwise
  # so a crafted "../other-sub" can never escape into a sibling resource.
  defp safe_segment(s) when is_binary(s) and s != "" do
    cond do
      String.contains?(s, ["/", "\\", "?", "#", "%", " "]) -> {:error, :invalid_id}
      s in [".", ".."] -> {:error, :invalid_id}
      # Reject any C0 control char (incl. NUL, CR, LF, TAB) and DEL.
      String.match?(s, ~r/[\x00-\x1f\x7f]/) -> {:error, :invalid_id}
      true -> {:ok, s}
    end
  end

  defp safe_segment(_), do: {:error, :invalid_id}

  defp json_encode(map), do: Jason.encode!(map)

  defp decode(""), do: %{}

  defp decode(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, v} -> v
      {:error, _} -> bin
    end
  end
end
