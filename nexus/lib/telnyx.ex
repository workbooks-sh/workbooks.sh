defmodule Nexus.Telnyx do
  @moduledoc """
  A thin client for the Telnyx v2 API plus the Ed25519 webhook verification that gates every inbound
  SMS/voice event — the host side of the phone channel that lets a paying tenant text/call their
  autopoet (epic wb-h0pey).

  Mirrors `Nexus.Polar` exactly (TLS verify_peer + pinned SNI, token never in `build_request`, fixed
  host, `safe_segment`, capped body, injectable `:http` seam). The channel itself is wired in the
  CLOUD layer (`/cloud/telnyx/webhook` ingress, number→tenant registry, `Nexus.Channels.Admission`);
  this module stays a neutral, no-op-safe mechanism any operator can point at their own Telnyx account.

  AUTH: a `Bearer` token from `TELNYX_API_KEY`, read through `Nexus.Secrets` — the ONE audited secret
  seam. The key is a HOST credential (broker pattern, like `POLAR_ACCESS_TOKEN`/`COMPOSIO_API_KEY`):
  it NEVER appears in a log line, an error tuple, any returned value, or a tenant machine. It lives
  only in the `authorization` header handed straight to `:httpc` (added in `do_request/5`, never in
  `build_request/4`).

  HOST: fixed module constant `https://api.telnyx.com` — never taken from caller/tenant input (SSRF
  floor). Path ids (`call_control_id`, verification ids) are validated as single opaque segments
  before interpolation.

  WEBHOOKS — `verify_webhook/3` implements Telnyx's Ed25519 scheme
  (https://developers.telnyx.com/docs/messaging/messages/receiving-webhooks): headers
  `telnyx-signature-ed25519` (base64) + `telnyx-timestamp`; signed content is
  `"<timestamp>|<raw_body>"`; the public key is the base64 account key from the portal. Fails closed:
  missing header, bad base64, out-of-tolerance timestamp, or signature mismatch all return
  `{:error, reason}`. Replay tolerance is 5 minutes, matching the Polar/Standard-Webhooks posture.

  ERRORS: non-2xx → `{:error, {status, body}}`, never raises. The HTTP layer is INJECTABLE: every
  public fn threads `opts` carrying `:http` (`fun(method, url, headers, body) -> {:ok, {status,
  body}} | {:error, term}`) so request construction is unit-testable with no network.

  ENDPOINTS — confirmed against the Telnyx API reference (https://developers.telnyx.com/api):
    * send a message            — POST /v2/messages
    * search available numbers  — GET  /v2/available_phone_numbers
    * order a number            — POST /v2/number_orders
    * create messaging profile  — POST /v2/messaging_profiles
    * toll-free verification    — POST /v2/messaging_tollfree/verification/requests (+ GET :id)
    * call actions              — POST /v2/calls/:call_control_id/actions/{answer,speak,hangup,ai_assistant_start}
  """

  @api_host "https://api.telnyx.com"
  @sni ~c"api.telnyx.com"

  # Telnyx signs `"<timestamp>|<raw_body>"`; reject deliveries whose timestamp is more than 5 minutes
  # away from now (past OR future) — replay defense, same tolerance as the Polar webhook gate.
  @tolerance_seconds 5 * 60

  @doc "The fixed Telnyx API host (never caller-supplied)."
  def api_host, do: @api_host

  @doc "True when a Telnyx API key is configured (the phone channel is live on this nexus)."
  def configured?, do: is_binary(Nexus.Secrets.get("TELNYX_API_KEY"))

  # ── Part A: Ed25519 webhook verification (the security keystone) ─────────────────

  @doc """
  Boolean webhook check for the ingress route — verifies the inbound Telnyx webhook against the
  `TELNYX_PUBLIC_KEY` (from `Nexus.Secrets`). `true` only on a valid, in-tolerance signature; fails
  closed (`false`) on a bad/missing signature or no configured key. Use `verify_webhook/3` when you
  want the parsed event or the failure reason.
  """
  def verify_webhook(payload_raw, headers) do
    case Nexus.Secrets.get("TELNYX_PUBLIC_KEY") do
      key when is_binary(key) -> match?({:ok, _}, verify_webhook(payload_raw, headers, key))
      _ -> false
    end
  end

  @doc """
  Verify an inbound Telnyx webhook and return `{:ok, parsed_event}` ONLY on a valid, in-tolerance
  Ed25519 signature.

    * `payload_raw` — the RAW request body bytes, exactly as received (the signed content is built
      from THIS, never a re-encoded JSON, or the signature won't match).
    * `headers`     — request headers as a map or `{name, value}` list (case-insensitive). Required:
      `telnyx-signature-ed25519`, `telnyx-timestamp`.
    * `public_key`  — the account's Ed25519 public key, base64 (32 raw bytes decoded), from the
      Telnyx portal (Keys & Credentials).

  Signed content is `"<timestamp>|<payload_raw>"`; verified with `:crypto.verify(:eddsa, ...)`.
  """
  def verify_webhook(payload_raw, headers, public_key)
      when is_binary(payload_raw) and is_binary(public_key) do
    with {:ok, sig_b64} <- fetch_header(headers, "telnyx-signature-ed25519"),
         {:ok, ts_raw} <- fetch_header(headers, "telnyx-timestamp"),
         {:ok, ts} <- parse_timestamp(ts_raw),
         :ok <- check_tolerance(ts),
         {:ok, key} <- decode_public_key(public_key),
         {:ok, sig} <- decode_signature(sig_b64),
         :ok <- verify_signature(ts_raw, payload_raw, key, sig) do
      parse_event(payload_raw)
    end
  end

  def verify_webhook(_payload, _headers, _public_key), do: {:error, :invalid_arguments}

  # Ed25519 verification is inherently constant-time in the underlying crypto — no comparison of
  # attacker-controlled bytes against a secret happens in Elixir. Signed content uses the raw header
  # timestamp string (not the parsed integer) so it is byte-for-byte what Telnyx signed.
  defp verify_signature(ts_raw, payload_raw, key, sig) do
    signed = ts_raw <> "|" <> payload_raw

    if :crypto.verify(:eddsa, :none, signed, sig, [key, :ed25519]) do
      :ok
    else
      {:error, :no_matching_signature}
    end
  rescue
    # A malformed key/signature makes :crypto raise — fail closed, never crash the ingress route.
    _ -> {:error, :no_matching_signature}
  end

  # The portal key is base64 of the 32 raw Ed25519 public-key bytes. Anything else fails closed.
  defp decode_public_key(b64) do
    case Base.decode64(String.trim(b64)) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      _ -> {:error, :malformed_public_key}
    end
  end

  # Ed25519 signatures are 64 raw bytes, base64 on the wire.
  defp decode_signature(b64) do
    case Base.decode64(String.trim(b64)) do
      {:ok, sig} when byte_size(sig) == 64 -> {:ok, sig}
      _ -> {:error, :malformed_signature}
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
    if abs(now - ts) <= @tolerance_seconds, do: :ok, else: {:error, :timestamp_out_of_tolerance}
  end

  # Case-insensitive header lookup over a map or a {name, value} list. Missing/empty fails closed.
  defp fetch_header(headers, name) when is_map(headers), do: fetch_header(Map.to_list(headers), name)

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
  Send an SMS/MMS. POST /v2/messages. `opts` (keyword/map): `:to` + `:text` required, `:from` or
  `:messaging_profile_id` (Telnyx picks the number from the profile) — at least one required,
  `:media_urls` (list, makes it MMS), `:webhook_url` (per-message status override).
  `{:error, :not_configured}` with no API key; `{:error, :missing_fields}` without to/text/sender.
  """
  def send_sms(opts) do
    opts = Map.new(opts)

    body =
      %{}
      |> put_some("to", opts[:to])
      |> put_some("text", opts[:text])
      |> put_some("from", opts[:from])
      |> put_some("messaging_profile_id", opts[:messaging_profile_id])
      |> put_some("media_urls", opts[:media_urls])
      |> put_some("webhook_url", opts[:webhook_url])

    cond do
      not (configured?() or is_binary(opts[:token])) -> {:error, :not_configured}
      body["to"] in [nil, ""] or body["text"] in [nil, ""] -> {:error, :missing_fields}
      body["from"] == nil and body["messaging_profile_id"] == nil -> {:error, :missing_fields}
      true -> request(:post, ["v2", "messages"], body, pass_opts(opts))
    end
  end

  @doc """
  Search purchasable numbers. GET /v2/available_phone_numbers. `opts[:filters]` is a plain map of
  Telnyx filter params, e.g. `%{"filter[phone_number_type]" => "toll_free",
  "filter[country_code]" => "US", "filter[features][]" => "sms", "filter[limit]" => 5}`.
  """
  def available_numbers(opts \\ []) do
    opts = Map.new(opts)
    request(:get, ["v2", "available_phone_numbers"], nil, [query: opts[:filters] || %{}] ++ pass_opts(opts))
  end

  @doc """
  Order (purchase) a phone number. POST /v2/number_orders. Optional `:messaging_profile_id` /
  `:connection_id` attach the number to messaging/voice at order time.
  """
  def order_number(phone_number, opts \\ []) when is_binary(phone_number) do
    opts = Map.new(opts)

    body =
      %{"phone_numbers" => [%{"phone_number" => phone_number}]}
      |> put_some("messaging_profile_id", opts[:messaging_profile_id])
      |> put_some("connection_id", opts[:connection_id])

    request(:post, ["v2", "number_orders"], body, pass_opts(opts))
  end

  @doc """
  Create a messaging profile whose inbound webhook points at our cloud ingress. POST
  /v2/messaging_profiles. One profile per customer (the ISV pattern below Managed Accounts scale).
  """
  def create_messaging_profile(name, webhook_url, opts \\ [])
      when is_binary(name) and is_binary(webhook_url) do
    opts = Map.new(opts)

    body =
      %{"name" => name, "webhook_url" => webhook_url, "enabled" => true, "webhook_api_version" => "2"}
      |> put_some("webhook_failover_url", opts[:webhook_failover_url])

    request(:post, ["v2", "messaging_profiles"], body, pass_opts(opts))
  end

  @doc """
  Submit a toll-free verification request for a number. POST
  /v2/messaging_tollfree/verification/requests. `body` carries the Telnyx-shaped verification form
  (business info, use case, opt-in description, sample messages) — the cloud layer owns that opinion.
  """
  def tollfree_verification(body, opts \\ []) when is_map(body) do
    request(:post, ["v2", "messaging_tollfree", "verification", "requests"], body, pass_opts(Map.new(opts)))
  end

  @doc "Fetch a toll-free verification request's status. GET /v2/messaging_tollfree/verification/requests/:id."
  def tollfree_verification_status(id, opts \\ []) do
    with {:ok, id} <- safe_segment(id) do
      request(:get, ["v2", "messaging_tollfree", "verification", "requests", id], nil, pass_opts(Map.new(opts)))
    end
  end

  # ── Voice (Call Control v2) ───────────────────────────────────────────────────────

  @doc "Answer a parked inbound call. POST /v2/calls/:ccid/actions/answer."
  def answer_call(call_control_id, opts \\ []),
    do: call_action(call_control_id, "answer", Map.new(opts)[:body] || %{}, Map.new(opts))

  @doc "Speak text on a live call (Telnyx TTS). POST /v2/calls/:ccid/actions/speak."
  def speak(call_control_id, text, opts \\ []) when is_binary(text) do
    opts = Map.new(opts)
    body = %{"payload" => text, "voice" => opts[:voice] || "female", "language" => opts[:language] || "en-US"}
    call_action(call_control_id, "speak", body, opts)
  end

  @doc "Hang up a call. POST /v2/calls/:ccid/actions/hangup."
  def hangup_call(call_control_id, opts \\ []),
    do: call_action(call_control_id, "hangup", %{}, Map.new(opts))

  @doc """
  Hand a live call to a Telnyx AI Assistant (the voice brain whose LLM base URL points at our
  `/cloud/telnyx/llm` shim). POST /v2/calls/:ccid/actions/ai_assistant_start. `body` carries the
  assistant reference, e.g. `%{"assistant" => %{"id" => "assistant-..."}}`.
  """
  def start_ai_assistant(call_control_id, body, opts \\ []) when is_map(body),
    do: call_action(call_control_id, "ai_assistant_start", body, Map.new(opts))

  defp call_action(call_control_id, action, body, opts) do
    with {:ok, ccid} <- safe_segment(call_control_id) do
      request(:post, ["v2", "calls", ccid, "actions", action], body, pass_opts(opts))
    end
  end

  # Forward only the injectable seams (used by tests) into the request layer.
  defp pass_opts(opts) when is_map(opts),
    do: Enum.filter([:http, :token], &Map.has_key?(opts, &1)) |> Enum.map(&{&1, opts[&1]})

  defp put_some(map, _k, nil), do: map
  defp put_some(map, _k, ""), do: map
  defp put_some(map, k, v), do: Map.put(map, k, v)

  # ── Pure request construction (network-free; unit-testable) ─────────────────────

  @doc """
  Build the `{method, url, headers, body}` 4-tuple WITHOUT performing it. Pure and network-free. The
  `Authorization: Bearer <token>` header is DELIBERATELY NOT added here — the token is injected only
  in the private HTTP layer (`do_request/5`), so it never appears in this pure return value, a log,
  or a test fixture. `opts[:query]` (map) is URL-encoded onto GET requests.
  """
  def build_request(method, segments, body, opts \\ []) when is_list(segments) do
    url = @api_host <> "/" <> Enum.join(segments, "/") <> query_string(Keyword.get(opts, :query))

    headers =
      [{"accept", "application/json"}] ++
        if(is_map(body), do: [{"content-type", "application/json"}], else: [])

    encoded = if is_map(body), do: Jason.encode!(body), else: ""
    {method, url, headers, encoded}
  end

  defp query_string(q) when is_map(q) and map_size(q) > 0, do: "?" <> URI.encode_query(q)
  defp query_string(_), do: ""

  @doc false
  # Pinned TLS http-options (same verify_peer pattern as `Nexus.Polar`/`Nexus.Fly`). Exposed so the
  # test can regression-lock verify_peer + non-empty cacerts + SNI.
  def http_options do
    [
      timeout: 30_000,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: @sni,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  # ── Internal: construct + dispatch + map ────────────────────────────────────────

  # Cap the response body read so a hostile/oversized response can't exhaust memory.
  @max_body_bytes 8 * 1024 * 1024

  defp request(method, segments, body, opts) do
    {method, url, headers, encoded} = build_request(method, segments, body, opts)
    token = Keyword.get(opts, :token) || Nexus.Secrets.get("TELNYX_API_KEY") || ""
    http = Keyword.get(opts, :http, &do_request(&1, &2, &3, &4, token))

    case http.(method, url, headers, encoded) do
      {:ok, {status, resp}} when status in 200..299 -> {:ok, decode(resp)}
      {:ok, {status, resp}} -> {:error, {status, decode(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Real HTTP via :httpc. The `Authorization: Bearer <token>` header is added HERE — never by
  # `build_request` — so the token lives only in the request handed straight to `:httpc`. TLS is
  # verified (verify_peer + pinned SNI) so the key can't be MITM-stolen. Never logs headers.
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

  # A path id (call_control_id, verification id) must be a single opaque segment. Fails closed so a
  # crafted "../other" can never escape into a sibling resource.
  defp safe_segment(s) when is_binary(s) and s != "" do
    cond do
      String.contains?(s, ["/", "\\", "?", "#", "%", " "]) -> {:error, :invalid_id}
      s in [".", ".."] -> {:error, :invalid_id}
      String.match?(s, ~r/[\x00-\x1f\x7f]/) -> {:error, :invalid_id}
      true -> {:ok, s}
    end
  end

  defp safe_segment(_), do: {:error, :invalid_id}

  defp decode(""), do: %{}

  defp decode(bin) when is_binary(bin) do
    case Jason.decode(bin) do
      {:ok, v} -> v
      {:error, _} -> bin
    end
  end
end
