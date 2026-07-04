defmodule Nexus.TelnyxTest do
  # async: false — some tests set process env (TELNYX_API_KEY / TELNYX_PUBLIC_KEY).
  use ExUnit.Case, async: false
  alias Nexus.Telnyx

  @token "KEY_SHOULD_NEVER_LEAK"

  # A real Ed25519 keypair generated per run — Telnyx's portal key is base64 of the 32 raw
  # public-key bytes, which is exactly what :crypto emits.
  defp keypair do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    {Base.encode64(pub), priv}
  end

  defp signed_headers(priv, opts \\ []) do
    ts = Keyword.get(opts, :ts, System.system_time(:second)) |> to_string()
    payload = Keyword.get(opts, :payload, ~s({"data":{"event_type":"message.received"}}))
    sig = :crypto.sign(:eddsa, :none, ts <> "|" <> payload, [priv, :ed25519]) |> Base.encode64()
    {%{"telnyx-signature-ed25519" => sig, "telnyx-timestamp" => ts}, payload}
  end

  # ── Part A: Ed25519 webhook verification ─────────────────────────────────────────

  describe "verify_webhook/3 — Ed25519 (the security keystone)" do
    test "accepts a correctly-signed, in-tolerance webhook and returns the parsed event" do
      {pub_b64, priv} = keypair()
      {headers, payload} = signed_headers(priv)

      assert {:ok, %{"data" => %{"event_type" => "message.received"}}} =
               Telnyx.verify_webhook(payload, headers, pub_b64)
    end

    test "accepts header names case-insensitively and from a {name,value} list" do
      {pub_b64, priv} = keypair()
      {map, payload} = signed_headers(priv)

      list = [
        {"Telnyx-Signature-Ed25519", map["telnyx-signature-ed25519"]},
        {"TELNYX-TIMESTAMP", map["telnyx-timestamp"]}
      ]

      assert {:ok, _} = Telnyx.verify_webhook(payload, list, pub_b64)
    end

    test "verify_webhook/2 reads TELNYX_PUBLIC_KEY and returns a boolean" do
      {pub_b64, priv} = keypair()
      System.put_env("TELNYX_PUBLIC_KEY", pub_b64)
      on_exit(fn -> System.delete_env("TELNYX_PUBLIC_KEY") end)

      {headers, payload} = signed_headers(priv)
      assert Telnyx.verify_webhook(payload, headers) == true
      refute Telnyx.verify_webhook(~s({"data":{}}), headers)
    end

    test "verify_webhook/2 fails closed when no public key is configured" do
      System.delete_env("TELNYX_PUBLIC_KEY")
      {_pub, priv} = keypair()
      {headers, payload} = signed_headers(priv)
      refute Telnyx.verify_webhook(payload, headers)
    end

    # ── Adversarial ──────────────────────────────────────────────────────────────

    test "rejects a TAMPERED payload (body differs from what was signed)" do
      {pub_b64, priv} = keypair()
      {headers, _payload} = signed_headers(priv)

      assert {:error, :no_matching_signature} =
               Telnyx.verify_webhook(~s({"data":"evil"}), headers, pub_b64)
    end

    test "rejects a signature from a DIFFERENT key (spoofed sender)" do
      {pub_b64, _priv} = keypair()
      {_other_pub, other_priv} = keypair()
      {headers, payload} = signed_headers(other_priv)

      assert {:error, :no_matching_signature} = Telnyx.verify_webhook(payload, headers, pub_b64)
    end

    test "rejects a TAMPERED timestamp (signed content is ts|body)" do
      {pub_b64, priv} = keypair()
      {headers, payload} = signed_headers(priv)
      headers = %{headers | "telnyx-timestamp" => to_string(System.system_time(:second) - 60)}

      assert {:error, :no_matching_signature} = Telnyx.verify_webhook(payload, headers, pub_b64)
    end

    test "rejects an OLD timestamp (outside the 5-minute tolerance) → replay defense" do
      {pub_b64, priv} = keypair()
      old = System.system_time(:second) - (5 * 60 + 1)
      {headers, payload} = signed_headers(priv, ts: old)

      assert {:error, :timestamp_out_of_tolerance} = Telnyx.verify_webhook(payload, headers, pub_b64)
    end

    test "rejects a FUTURE timestamp outside tolerance too" do
      {pub_b64, priv} = keypair()
      future = System.system_time(:second) + (5 * 60 + 1)
      {headers, payload} = signed_headers(priv, ts: future)

      assert {:error, :timestamp_out_of_tolerance} = Telnyx.verify_webhook(payload, headers, pub_b64)
    end

    test "rejects missing signature / timestamp headers" do
      {pub_b64, priv} = keypair()
      {headers, payload} = signed_headers(priv)

      assert {:error, {:missing_header, "telnyx-signature-ed25519"}} =
               Telnyx.verify_webhook(payload, Map.delete(headers, "telnyx-signature-ed25519"), pub_b64)

      assert {:error, {:missing_header, "telnyx-timestamp"}} =
               Telnyx.verify_webhook(payload, Map.delete(headers, "telnyx-timestamp"), pub_b64)
    end

    test "rejects a malformed (non-base64 / wrong-size) public key" do
      {_pub, priv} = keypair()
      {headers, payload} = signed_headers(priv)

      assert {:error, :malformed_public_key} = Telnyx.verify_webhook(payload, headers, "!!!not base64!!!")
      assert {:error, :malformed_public_key} = Telnyx.verify_webhook(payload, headers, Base.encode64("short"))
    end

    test "rejects a malformed (non-base64 / wrong-size) signature" do
      {pub_b64, priv} = keypair()
      {headers, payload} = signed_headers(priv)

      for bad <- ["!!!", Base.encode64("too-short"), ""] do
        h = %{headers | "telnyx-signature-ed25519" => bad}
        assert match?({:error, _}, Telnyx.verify_webhook(payload, h, pub_b64)),
               "malformed sig #{inspect(bad)} must fail closed"
      end
    end

    test "rejects a non-integer timestamp" do
      {pub_b64, priv} = keypair()
      {headers, payload} = signed_headers(priv)
      headers = %{headers | "telnyx-timestamp" => "not-a-number"}

      assert {:error, :bad_timestamp} = Telnyx.verify_webhook(payload, headers, pub_b64)
    end

    test "a valid signature over a non-JSON body → :invalid_payload (verify before parse)" do
      {pub_b64, priv} = keypair()
      {headers, payload} = signed_headers(priv, payload: "not json")

      assert {:error, :invalid_payload} = Telnyx.verify_webhook(payload, headers, pub_b64)
    end
  end

  # ── Part B: API client ──────────────────────────────────────────────────────────

  describe "build_request/4 (pure construction, no network)" do
    test "send path is POST /v2/messages with NO auth header" do
      {method, url, headers, body} =
        Telnyx.build_request(:post, ["v2", "messages"], %{"to" => "+15551234567", "text" => "hi"}, token: @token)

      assert method == :post
      assert url == "https://api.telnyx.com/v2/messages"
      refute Enum.any?(headers, fn {k, _} -> k == "authorization" end)
      assert {"content-type", "application/json"} in headers
      assert Jason.decode!(body) == %{"to" => "+15551234567", "text" => "hi"}
    end

    test "GET carries an encoded query string, no content-type, empty body" do
      {_m, url, headers, body} =
        Telnyx.build_request(:get, ["v2", "available_phone_numbers"], nil,
          query: %{"filter[phone_number_type]" => "toll_free"})

      assert url == "https://api.telnyx.com/v2/available_phone_numbers?" <>
               URI.encode_query(%{"filter[phone_number_type]" => "toll_free"})

      assert body == ""
      refute Enum.any?(headers, fn {k, _} -> k == "content-type" end)
    end
  end

  describe "send_sms/1" do
    test ":not_configured without an API key" do
      System.delete_env("TELNYX_API_KEY")
      assert Telnyx.send_sms(to: "+15551234567", text: "hi", from: "+18885551000") == {:error, :not_configured}
    end

    test ":missing_fields without to/text or any sender identity" do
      assert Telnyx.send_sms(%{text: "hi", from: "+1", token: @token}) == {:error, :missing_fields}
      assert Telnyx.send_sms(%{to: "+1", from: "+1", token: @token}) == {:error, :missing_fields}
      assert Telnyx.send_sms(%{to: "+1", text: "hi", token: @token}) == {:error, :missing_fields}
    end

    test "builds the message body and returns the created message" do
      http = fn :post, url, _h, body ->
        assert url == "https://api.telnyx.com/v2/messages"
        decoded = Jason.decode!(body)
        assert decoded["to"] == "+15551234567"
        assert decoded["from"] == "+18885551000"
        assert decoded["text"] == "hello from your autopoet"
        {:ok, {200, ~s({"data":{"id":"msg_1"}})}}
      end

      assert {:ok, %{"data" => %{"id" => "msg_1"}}} =
               Telnyx.send_sms(%{to: "+15551234567", from: "+18885551000",
                 text: "hello from your autopoet", http: http, token: @token})
    end

    test "messaging_profile_id is an acceptable sender identity" do
      http = fn :post, _url, _h, body ->
        assert Jason.decode!(body)["messaging_profile_id"] == "mp_1"
        {:ok, {200, ~s({"data":{}})}}
      end

      assert {:ok, _} =
               Telnyx.send_sms(%{to: "+1", text: "hi", messaging_profile_id: "mp_1", http: http, token: @token})
    end
  end

  describe "provisioning calls (pure construction through the injectable seam)" do
    test "order_number wraps the number and attaches the messaging profile" do
      http = fn :post, url, _h, body ->
        assert url == "https://api.telnyx.com/v2/number_orders"
        assert Jason.decode!(body) == %{
                 "phone_numbers" => [%{"phone_number" => "+18885551000"}],
                 "messaging_profile_id" => "mp_1"
               }
        {:ok, {200, ~s({"data":{"id":"order_1"}})}}
      end

      assert {:ok, %{"data" => %{"id" => "order_1"}}} =
               Telnyx.order_number("+18885551000", messaging_profile_id: "mp_1", http: http, token: @token)
    end

    test "create_messaging_profile points the webhook at our ingress, api v2" do
      http = fn :post, url, _h, body ->
        assert url == "https://api.telnyx.com/v2/messaging_profiles"
        decoded = Jason.decode!(body)
        assert decoded["name"] == "org_42"
        assert decoded["webhook_url"] == "https://wb-dogfood.fly.dev/cloud/telnyx/webhook"
        assert decoded["webhook_api_version"] == "2"
        assert decoded["enabled"] == true
        assert decoded["whitelisted_destinations"] == ["US"]
        {:ok, {200, ~s({"data":{"id":"mp_1"}})}}
      end

      assert {:ok, %{"data" => %{"id" => "mp_1"}}} =
               Telnyx.create_messaging_profile("org_42", "https://wb-dogfood.fly.dev/cloud/telnyx/webhook",
                 http: http, token: @token)
    end

    test "available_numbers encodes the filter map" do
      http = fn :get, url, _h, "" ->
        assert url =~ "https://api.telnyx.com/v2/available_phone_numbers?"
        assert url =~ URI.encode_query(%{"filter[phone_number_type]" => "toll_free"})
        {:ok, {200, ~s({"data":[]})}}
      end

      assert {:ok, %{"data" => []}} =
               Telnyx.available_numbers(filters: %{"filter[phone_number_type]" => "toll_free"},
                 http: http, token: @token)
    end
  end

  describe "voice call actions" do
    test "answer/speak/hangup/ai_assistant_start target /v2/calls/:ccid/actions/:action" do
      seen = :ets.new(:seen, [:public])

      http = fn :post, url, _h, _body ->
        :ets.insert(seen, {url, true})
        {:ok, {200, ~s({"data":{"result":"ok"}})}}
      end

      assert {:ok, _} = Telnyx.answer_call("cc_1", http: http, token: @token)
      assert {:ok, _} = Telnyx.speak("cc_1", "hello", http: http, token: @token)
      assert {:ok, _} = Telnyx.hangup_call("cc_1", http: http, token: @token)

      assert {:ok, _} =
               Telnyx.start_ai_assistant("cc_1", %{"assistant" => %{"id" => "asst_1"}},
                 http: http, token: @token)

      urls = :ets.tab2list(seen) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

      assert urls == Enum.sort([
               "https://api.telnyx.com/v2/calls/cc_1/actions/answer",
               "https://api.telnyx.com/v2/calls/cc_1/actions/speak",
               "https://api.telnyx.com/v2/calls/cc_1/actions/hangup",
               "https://api.telnyx.com/v2/calls/cc_1/actions/ai_assistant_start"
             ])
    end

    test "speak carries the payload/voice/language body" do
      http = fn :post, _url, _h, body ->
        decoded = Jason.decode!(body)
        assert decoded["payload"] == "text me instead"
        assert is_binary(decoded["voice"]) and is_binary(decoded["language"])
        {:ok, {200, "{}"}}
      end

      assert {:ok, _} = Telnyx.speak("cc_1", "text me instead", http: http, token: @token)
    end
  end

  describe "id validation (SSRF / path-escape floor)" do
    test "a slash / dot-segment / query char in a call_control_id fails closed" do
      http = fn _m, _u, _h, _b -> flunk("should not have dispatched") end

      for bad <- ["../other", "a/b", "..", "a?x=1", "a#frag", "a b", ""] do
        assert {:error, :invalid_id} = Telnyx.answer_call(bad, http: http, token: @token)
        assert {:error, :invalid_id} = Telnyx.tollfree_verification_status(bad, http: http, token: @token)
      end
    end

    test "api host is the fixed constant, never caller-supplied" do
      assert Telnyx.api_host() == "https://api.telnyx.com"
    end
  end

  describe "HTTP layer is injectable; error mapping" do
    test "non-2xx → {:error, {status, body}}, never raises" do
      http = fn _m, _u, _h, _b -> {:ok, {422, ~s({"errors":[{"detail":"bad"}]})}} end

      assert {:error, {422, %{"errors" => [%{"detail" => "bad"}]}}} =
               Telnyx.send_sms(%{to: "+1", text: "x", from: "+2", http: http, token: @token})
    end

    test "transport error is propagated as {:error, reason}" do
      http = fn _m, _u, _h, _b -> {:error, :timeout} end
      assert {:error, :timeout} = Telnyx.available_numbers(http: http, token: @token)
    end
  end

  describe "token never leaks" do
    test "token absent from every returned value (ok, error, transport-error, invalid)" do
      results = [
        Telnyx.send_sms(%{to: "+1", text: "x", from: "+2", http: fn _, _, _, _ -> {:ok, {200, "{}"}} end, token: @token}),
        Telnyx.available_numbers(http: fn _, _, _, _ -> {:ok, {500, ~s({"e":"boom"})}} end, token: @token),
        Telnyx.available_numbers(http: fn _, _, _, _ -> {:error, :nxdomain} end, token: @token),
        Telnyx.answer_call("../bad", http: fn _, _, _, _ -> :ok end, token: @token)
      ]

      for r <- results do
        refute inspect(r) =~ @token
        refute inspect(r) =~ "Bearer"
      end
    end

    test "build_request output contains no token at all (url, headers, body)" do
      tuple = Telnyx.build_request(:post, ["v2", "messages"], %{"k" => "v"}, token: @token)
      refute inspect(tuple) =~ @token
      refute inspect(tuple) =~ "Bearer"
      refute inspect(tuple) =~ "authorization"
    end

    test "TELNYX_API_KEY is on the privileged scrub list (never visible to untrusted subprocesses)" do
      assert "TELNYX_API_KEY" in Nexus.Secrets.privileged_env_names()
    end
  end

  describe "TLS is verified (no MITM of the Telnyx API key)" do
    test "http_options pin verify_peer, a non-empty CA store, and the host SNI" do
      opts = Telnyx.http_options()
      ssl = Keyword.fetch!(opts, :ssl)

      assert Keyword.get(ssl, :verify) == :verify_peer
      cacerts = Keyword.get(ssl, :cacerts)
      assert is_list(cacerts) and cacerts != []
      assert Keyword.get(ssl, :server_name_indication) == ~c"api.telnyx.com"
      assert Keyword.has_key?(ssl, :customize_hostname_check)
    end
  end
end
