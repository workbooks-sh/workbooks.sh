defmodule Nexus.TelnyxChannelTest do
  @moduledoc """
  LIVE integration of the Telnyx phone channel (wb-h0pey) — boots a REAL Bandit server with the ACTUAL
  `dogfood/cloud` workbook mounted (so the real `/cloud/telnyx/webhook` + `/cloud/channels/*` routes
  exist), multi-tenant `auth=Cloud`, then drives the ingress with REAL Ed25519-signed webhooks over
  real sockets:

    * signature gate: unsigned/tampered → 401; signed → processed
    * number → tenant resolution through OUR registry; unroutable numbers acked + ignored
    * event-id dedup (Telnyx retries must not double-run the brain)
    * STOP/opt-out ledger, unlinked-caller nag (rate-limited), linked-caller conversation thread
    * the channel money gate (zero balance ⇒ silent block, event trail only)
    * phone-link OTP flow (start needs a sendable channel; verify is constant-time, tries-capped, TTL'd)
    * channel policy save (admin) + provisioning fail-closed without TELNYX_API_KEY
    * voice events are acked and act only when Telnyx is configured (no network from a bare box)

  No Telnyx key is configured, so every outbound send fails `{:error, :not_configured}` — which is
  exactly the production posture this suite locks: inbound processing NEVER depends on outbound
  deliverability, and a bare nexus makes no network calls. Skips cleanly if git is unavailable.
  """
  use ExUnit.Case, async: false
  @moduletag :integration
  @moduletag timeout: 300_000

  alias Nexus.ControlPlane, as: CP

  @port 4123
  @base ~c"http://127.0.0.1:#{@port}"
  @org "org_a"
  @num "+18885550001"
  @linked "+15551230000"

  setup_all do
    if System.find_executable("git") do
      Application.ensure_all_started(:inets)

      prev_auth = Application.get_env(:nexus, :auth)
      Application.put_env(:nexus, :auth, Nexus.Auth.Cloud)
      System.put_env("WB_CONTROL_PLANE", "1")
      System.put_env("NEXUS_TENANT", @org)
      System.delete_env("TELNYX_API_KEY")

      {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
      System.put_env("TELNYX_PUBLIC_KEY", Base.encode64(pub))

      base = Path.join(System.tmp_dir!(), "wb-telnyx-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      prev_data = System.get_env("WB_DATA")
      System.put_env("WB_DATA", base)
      cloud_root = Path.expand("../dogfood/cloud", File.cwd!())

      CP.reset()
      Nexus.Auth.TokenStore.ensure(:cp_tokens)

      {:ok, pid} = Nexus.Server.start_link(root: cloud_root, port: @port)
      wait_health()

      # The registry both ways: number → tenant (ingress) and tenant → number (egress), plus a linked
      # caller and a funded channel policy.
      CP.put(@org, :phone_number, @num, %{tenant: @org, agent: nil, profile_id: "mp_test", status: "active"})
      CP.put(@org, :channel, "phone", %{numbers: [@num], agent: nil})
      CP.put(@org, :phone_link, @linked, %{user: "m@t", verified: true, at: System.system_time(:second)})
      fund()

      admin = Nexus.ControlPlane.Token.mint(@org, "adm", role: "admin", user: "a@t").token
      member = Nexus.ControlPlane.Token.mint(@org, "mem", role: "member", user: "m@t").token

      on_exit(fn ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        if prev_auth, do: Application.put_env(:nexus, :auth, prev_auth), else: Application.delete_env(:nexus, :auth)
        if prev_data, do: System.put_env("WB_DATA", prev_data), else: System.delete_env("WB_DATA")
        System.delete_env("WB_CONTROL_PLANE")
        System.delete_env("NEXUS_TENANT")
        System.delete_env("TELNYX_PUBLIC_KEY")
        File.rm_rf(base)
      end)

      {:ok, priv: priv, admin: admin, member: member}
    else
      {:ok, skip: true}
    end
  end

  defp skipping?(ctx), do: Map.get(ctx, :skip, false)

  defp fund do
    CP.put(@org, :channels, "config",
      %{enforce: true, balance: 5.0, spent_mtd: 0.0, caps: %{sms: true, voice: true}, rates: %{sms: 0.02, voice: 0.15}})
  end

  # ── HTTP over real sockets ────────────────────────────────────────────────────

  defp req(method, path, token, body \\ nil) do
    headers =
      [{~c"accept", ~c"application/json"}, {~c"authorization", String.to_charlist("Bearer " <> token)}]

    url = @base ++ String.to_charlist(path)

    request =
      if body, do: {url, headers, ~c"application/json", Jason.encode!(body)}, else: {url, headers}

    {:ok, {{_, status, _}, _h, resp}} =
      :httpc.request(method, request, [{:timeout, 60_000}], [{:body_format, :binary}])

    {status, resp}
  end

  # A REAL Ed25519-signed Telnyx delivery: signed content is "<ts>|<raw_body>".
  defp post_signed(event, priv, opts \\ []) do
    raw = Jason.encode!(event)
    ts = Keyword.get(opts, :ts, System.system_time(:second)) |> to_string()
    sig = :crypto.sign(:eddsa, :none, ts <> "|" <> raw, [priv, :ed25519]) |> Base.encode64()

    headers = [
      {~c"accept", ~c"application/json"},
      {~c"telnyx-signature-ed25519", String.to_charlist(Keyword.get(opts, :sig, sig))},
      {~c"telnyx-timestamp", String.to_charlist(ts)}
    ]

    {:ok, {{_, status, _}, _h, resp}} =
      :httpc.request(:post, {@base ++ ~c"/cloud/telnyx/webhook", headers, ~c"application/json", raw},
        [{:timeout, 60_000}], [{:body_format, :binary}])

    {status, Jason.decode!(resp)}
  end

  defp sms_event(from, text, opts \\ []) do
    %{"data" => %{
        "event_type" => "message.received",
        "id" => Keyword.get(opts, :id, "evt_#{System.unique_integer([:positive])}"),
        "payload" => %{
          "from" => %{"phone_number" => from},
          "to" => [%{"phone_number" => Keyword.get(opts, :to, @num)}],
          "text" => text
        }}}
  end

  defp wait_health(n \\ 600) do
    case :httpc.request(:get, {@base ++ ~c"/health", []}, [{:timeout, 1000}], []) do
      {:ok, {{_, 200, _}, _, _}} -> :ok
      _ when n > 0 -> Process.sleep(200); wait_health(n - 1)
      _ -> flunk("cloud server never became healthy on :#{@port}")
    end
  end

  # ── the signature gate ────────────────────────────────────────────────────────

  test "an unsigned webhook is rejected 401 (fail closed)", ctx do
    skipping?(ctx) && throw(:skip)

    {:ok, {{_, status, _}, _, _}} =
      :httpc.request(:post, {@base ++ ~c"/cloud/telnyx/webhook", [], ~c"application/json",
        Jason.encode!(sms_event(@linked, "hi"))}, [{:timeout, 30_000}], [{:body_format, :binary}])

    assert status == 401
  end

  test "a webhook signed by a DIFFERENT key is rejected 401", ctx do
    skipping?(ctx) && throw(:skip)
    {_pub, other_priv} = :crypto.generate_key(:eddsa, :ed25519)
    {status, _} = post_signed(sms_event(@linked, "spoof"), other_priv)
    assert status == 401
  end

  # ── routing + conversation ───────────────────────────────────────────────────

  test "a signed text from a LINKED caller runs the brain, stores the thread, and dedups replays", ctx do
    skipping?(ctx) && throw(:skip)
    fund()
    id = "evt_thread_#{System.unique_integer([:positive])}"

    {200, body} = post_signed(sms_event(@linked, "hello autopoet", id: id), ctx.priv)
    assert body["ok"] == true
    refute body["deduped"]

    # The conversation memory landed: one user + one assistant turn.
    assert {:ok, %{turns: [first, second]}} = CP.get(@org, :sms_thread, @linked)
    assert first[:role] == "user" and first[:text] == "hello autopoet"
    assert second[:role] == "assistant" and is_binary(second[:text]) and second[:text] != ""

    # Telnyx retries the SAME delivery → the brain must not run twice.
    {200, body2} = post_signed(sms_event(@linked, "hello autopoet", id: id), ctx.priv)
    assert body2["deduped"] == true
  end

  test "a number we hold no routing for is ACKED and ignored (Telnyx stops retrying)", ctx do
    skipping?(ctx) && throw(:skip)
    {200, body} = post_signed(sms_event(@linked, "hi", to: "+19998887777"), ctx.priv)
    assert body["ok"] == true
    assert body["ignored"] == true
  end

  # ── compliance + identity ────────────────────────────────────────────────────

  test "STOP records the opt-out and later texts from that number are dropped silently", ctx do
    skipping?(ctx) && throw(:skip)
    fund()
    stranger = "+15559990001"

    {200, body} = post_signed(sms_event(stranger, "STOP"), ctx.priv)
    assert body["opted_out"] == true
    assert {:ok, _} = CP.get(@org, :phone_optout, stranger)

    {200, body2} = post_signed(sms_event(stranger, "hello?"), ctx.priv)
    assert body2["opted_out"] == true
    # Dropped BEFORE the unlinked nag — an opted-out stranger costs us nothing.
    assert {:error, :not_found} = CP.get(@org, :phone_nag, stranger)
  end

  test "an UNLINKED caller gets the link nudge, rate-limited to one per 24h", ctx do
    skipping?(ctx) && throw(:skip)
    fund()
    stranger = "+15559990002"

    {200, body} = post_signed(sms_event(stranger, "who is this"), ctx.priv)
    assert body["unlinked"] == true
    assert {:ok, %{at: at}} = CP.get(@org, :phone_nag, stranger)

    # Second probe inside the window: still acked, nag marker NOT refreshed (no second paid send).
    {200, _} = post_signed(sms_event(stranger, "hello again"), ctx.priv)
    assert {:ok, %{at: ^at}} = CP.get(@org, :phone_nag, stranger)

    # No brain run for strangers: no thread.
    assert {:error, :not_found} = CP.get(@org, :sms_thread, stranger)
  end

  test "a drained channel blocks silently — no reply, no nag, no thread (the money gate)", ctx do
    skipping?(ctx) && throw(:skip)

    CP.put(@org, :channels, "config",
      %{enforce: true, balance: 0.0, spent_mtd: 0.0, caps: %{sms: true, voice: true}, rates: %{sms: 0.02}})

    caller = "+15559990003"
    {200, body} = post_signed(sms_event(caller, "anyone home?"), ctx.priv)
    assert body["blocked"] == true
    assert {:error, :not_found} = CP.get(@org, :phone_nag, caller)
    assert {:error, :not_found} = CP.get(@org, :sms_thread, caller)

    fund()
  end

  # ── phone-link OTP flow ──────────────────────────────────────────────────────

  test "link start: invalid phone → 400; valid phone stores the OTP (send fails 502 without a Telnyx key)", ctx do
    skipping?(ctx) && throw(:skip)
    fund()

    {400, _} = req(:post, "/cloud/channels/phone/link", ctx.member, %{phone: "not-a-phone"})

    {status, _} = req(:post, "/cloud/channels/phone/link", ctx.member, %{phone: "+15551239999"})
    assert status == 502, "no TELNYX_API_KEY ⇒ the OTP text cannot send ⇒ 502 (got #{status})"
    assert {:ok, %{user: "m@t", code: code}} = CP.get(@org, :phone_otp, "+15551239999")
    assert String.length(to_string(code)) == 6
  end

  test "link verify: wrong code counts a try; right code links; expiry kills the OTP", ctx do
    skipping?(ctx) && throw(:skip)
    phone = "+15551238888"
    now = System.system_time(:second)
    CP.put(@org, :phone_otp, phone, %{code: "123456", user: "m@t", at: now, tries: 0})

    {400, _} = req(:post, "/cloud/channels/phone/verify", ctx.member, %{phone: phone, code: "000000"})
    assert {:ok, %{tries: 1}} = CP.get(@org, :phone_otp, phone)

    {200, resp} = req(:post, "/cloud/channels/phone/verify", ctx.member, %{phone: phone, code: "123456"})
    assert Jason.decode!(resp)["ok"] == true
    assert {:ok, %{verified: true, user: "m@t"}} = CP.get(@org, :phone_link, phone)
    assert {:error, :not_found} = CP.get(@org, :phone_otp, phone)

    # Expired OTP fails closed and is destroyed.
    stale = "+15551237777"
    CP.put(@org, :phone_otp, stale, %{code: "123456", user: "m@t", at: now - 601, tries: 0})
    {400, _} = req(:post, "/cloud/channels/phone/verify", ctx.member, %{phone: stale, code: "123456"})
    assert {:error, :not_found} = CP.get(@org, :phone_otp, stale)
  end

  # ── management + fail-closed provisioning ────────────────────────────────────

  test "channel policy save is admin-only and persists the kill switch", ctx do
    skipping?(ctx) && throw(:skip)
    fund()

    {403, _} = req(:post, "/cloud/channels/config", ctx.member, %{caps: %{voice: false}})

    {200, resp} = req(:post, "/cloud/channels/config", ctx.admin, %{caps: %{voice: false}, monthly_cap: 9.0})
    decoded = Jason.decode!(resp)
    assert decoded["config"]["caps"]["voice"] == false
    assert decoded["config"]["caps"]["sms"] == true
    assert decoded["config"]["monthly_cap"] == 9.0
    # The ledger fields are NOT writable through this route.
    assert {:ok, %{balance: 5.0}} = CP.get(@org, :channels, "config")

    fund()
  end

  test "provisioning without TELNYX_API_KEY is 503 (fail closed, no half-provisioned state)", ctx do
    skipping?(ctx) && throw(:skip)
    {503, _} = req(:post, "/cloud/channels/phone/provision", ctx.admin, %{agent: "autopilot"})
  end

  test "phone status reports numbers + policy to a member", ctx do
    skipping?(ctx) && throw(:skip)
    fund()
    {200, resp} = req(:get, "/cloud/channels/phone", ctx.member)
    decoded = Jason.decode!(resp)
    assert decoded["numbers"] == [@num]
    assert decoded["configured"] == false
    assert decoded["config"]["enforce"] == true
  end

  # ── the voice brain shim (OpenAI-compatible custom LLM) ──────────────────────

  test "voice token mint is admin-only; the bearer reaches the tenant brain via /cloud/telnyx/llm", ctx do
    skipping?(ctx) && throw(:skip)
    fund()

    {403, _} = req(:post, "/cloud/channels/voice/token", ctx.member, %{agent: "autopilot"})

    {200, resp} = req(:post, "/cloud/channels/voice/token", ctx.admin, %{agent: "autopilot"})
    %{"token" => tok, "base_url" => base_url} = Jason.decode!(resp)
    assert String.starts_with?(tok, "wbt_")
    assert String.ends_with?(base_url, "/cloud/telnyx/llm")

    # No bearer → OpenAI-shaped 401. A garbage bearer too.
    {401, _} = req(:post, "/cloud/telnyx/llm", "nope", %{messages: [%{role: "user", content: "hi"}]})

    # The minted bearer runs the brain and returns a chat.completion.
    body = %{model: "workbooks-autopoet", messages: [
      %{role: "system", content: "You are the caller's autopoet."},
      %{role: "user", content: "Say hello in one sentence."}]}

    {200, resp2} = req(:post, "/cloud/telnyx/llm/chat/completions", tok, body)
    decoded = Jason.decode!(resp2)
    assert decoded["object"] == "chat.completion"
    assert [%{"message" => %{"role" => "assistant", "content" => content}, "finish_reason" => "stop"}] = decoded["choices"]
    assert is_binary(content) and content != ""

    # stream: true → a valid one-shot SSE ending in [DONE].
    {200, sse} = req(:post, "/cloud/telnyx/llm", tok, Map.put(body, :stream, true))
    assert String.starts_with?(sse, "data: ")
    assert String.contains?(sse, ~s("object":"chat.completion.chunk"))
    assert String.ends_with?(sse, "data: [DONE]\n\n")
  end

  test "the shim honors the voice kill switch (402, OpenAI error shape)", ctx do
    skipping?(ctx) && throw(:skip)

    {200, resp} = req(:post, "/cloud/channels/voice/token", ctx.admin, %{agent: "autopilot"})
    tok = Jason.decode!(resp)["token"]

    CP.put(@org, :channels, "config",
      %{enforce: true, balance: 5.0, caps: %{sms: true, voice: false}, rates: %{sms: 0.02}})

    {402, resp2} = req(:post, "/cloud/telnyx/llm", tok, %{messages: [%{role: "user", content: "hi"}]})
    assert Jason.decode!(resp2)["error"]["type"] == "insufficient_quota"

    fund()
  end

  # ── voice acks ───────────────────────────────────────────────────────────────

  test "voice events are acked; an unconfigured nexus takes no call action (no network)", ctx do
    skipping?(ctx) && throw(:skip)

    call = %{"data" => %{
      "event_type" => "call.initiated",
      "id" => "evt_call_#{System.unique_integer([:positive])}",
      "payload" => %{"call_control_id" => "cc_test", "direction" => "incoming",
        "from" => "+15551230000", "to" => @num}}}

    {200, body} = post_signed(call, ctx.priv)
    # Telnyx unconfigured ⇒ the with-chain falls through to the ack without answering.
    assert body["ok"] == true
    assert body["ignored"] == true
  end
end
