defmodule Nexus.PolarTest do
  # async: false — these reload the global Nexus.Config (persistent_term).
  use ExUnit.Case, async: false
  alias Nexus.Polar

  @token "polar_oat_SHOULD_NEVER_LEAK"

  # The API-client URL/SNI assertions below pin the PRODUCTION host. Default the config to production for
  # this file; the dedicated config describe-block flips it back to exercise the sandbox default.
  setup do
    Nexus.Config.put(:polar_server, "production")
    on_exit(fn -> Nexus.Config.reload(nil) end)
    :ok
  end

  # ── server selection (our cloud's config; sandbox default) ──────────────────────
  describe "server selection (Nexus.Config.polar_server)" do
    test "defaults to sandbox host + SNI" do
      Nexus.Config.reload(nil)
      assert Nexus.Config.polar_server() == "sandbox"
      assert Polar.api_host() == "https://sandbox-api.polar.sh"
      assert Keyword.get(Polar.http_options()[:ssl], :server_name_indication) == ~c"sandbox-api.polar.sh"
    end

    test "production host + SNI when the deploy block selects it" do
      Nexus.Config.reload(~s(deploy do\n  polar-server="production"\nend))
      assert Polar.api_host() == "https://api.polar.sh"
      assert Keyword.get(Polar.http_options()[:ssl], :server_name_indication) == ~c"api.polar.sh"
    end

    test "product UUIDs + credit product come from the deploy block" do
      src = """
      deploy do
        polar-product-starter="prod_starter"
        polar-product-team="prod_team"
        polar-credit-product="prod_credit"
      end
      """

      Nexus.Config.reload(src)
      assert Nexus.Config.polar_product("starter") == "prod_starter"
      assert Nexus.Config.polar_product("team") == "prod_team"
      assert Nexus.Config.polar_product("scale") == nil
      assert Nexus.Config.polar_credit_product() == "prod_credit"
    end
  end

  # ── Part A: Standard-Webhooks verification ──────────────────────────────────────

  describe "verify_webhook/3 — Standard Webhooks (the security keystone)" do
    @secret "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
    @msg_id "msg_p5jXN8AQM9LWM0D4loKWxJek"
    @vector_ts 1_614_265_330
    @payload ~s({"test": 2432232314})
    @vector_sig "g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="

    defp valid_headers(opts \\ []) do
      id = Keyword.get(opts, :id, @msg_id)
      ts = Keyword.get(opts, :ts, System.system_time(:second)) |> to_string()
      payload = Keyword.get(opts, :payload, @payload)
      secret = Keyword.get(opts, :secret, @secret)

      key = secret |> String.replace_prefix("whsec_", "") |> Base.decode64!()
      signed = "#{id}.#{ts}.#{payload}"
      sig = :crypto.mac(:hmac, :sha256, key, signed) |> Base.encode64()

      {%{"webhook-id" => id, "webhook-timestamp" => ts, "webhook-signature" => "v1," <> sig}, payload}
    end

    test "the canonical vector produces the documented signature (signed-content lock)" do
      key = @secret |> String.replace_prefix("whsec_", "") |> Base.decode64!()
      signed = "#{@msg_id}.#{@vector_ts}.#{@payload}"
      computed = :crypto.mac(:hmac, :sha256, key, signed) |> Base.encode64()
      assert computed == @vector_sig
    end

    test "accepts a correctly-signed, in-tolerance webhook and returns the parsed event" do
      {headers, payload} = valid_headers()
      assert {:ok, %{"test" => 2_432_232_314}} = Polar.verify_webhook(payload, headers, @secret)
    end

    test "accepts when ANY v1 entry in a space-separated list matches (key rotation)" do
      {headers, payload} = valid_headers()
      multi = "v1,AAAAbogusAAAA= " <> headers["webhook-signature"] <> " v1a,asymmetric-ignored"
      headers = %{headers | "webhook-signature" => multi}
      assert {:ok, _} = Polar.verify_webhook(payload, headers, @secret)
    end

    test "accepts header names case-insensitively and from a {name,value} list" do
      {map, payload} = valid_headers()

      list = [
        {"Webhook-Id", map["webhook-id"]},
        {"WEBHOOK-TIMESTAMP", map["webhook-timestamp"]},
        {"Webhook-Signature", map["webhook-signature"]}
      ]

      assert {:ok, _} = Polar.verify_webhook(payload, list, @secret)
    end

    # The boolean dashboard wrapper pulls the secret from Nexus.Secrets (the env).
    test "verify_webhook/2 reads POLAR_WEBHOOK_SECRET and returns a boolean" do
      System.put_env("POLAR_WEBHOOK_SECRET", @secret)
      on_exit(fn -> System.delete_env("POLAR_WEBHOOK_SECRET") end)
      {headers, payload} = valid_headers()
      assert Polar.verify_webhook(payload, headers) == true
      refute Polar.verify_webhook(~s({"test": 9999}), headers)
    end

    test "verify_webhook/2 fails closed when no secret is configured" do
      System.delete_env("POLAR_WEBHOOK_SECRET")
      {headers, payload} = valid_headers()
      refute Polar.verify_webhook(payload, headers)
    end

    # ── Adversarial ──────────────────────────────────────────────────────────────

    test "rejects a TAMPERED payload (body differs from what was signed)" do
      {headers, _payload} = valid_headers()
      assert {:error, :no_matching_signature} = Polar.verify_webhook(~s({"test": 9999}), headers, @secret)
    end

    test "rejects a TAMPERED signature" do
      {headers, payload} = valid_headers()
      bad = String.replace_prefix(headers["webhook-signature"], "v1,", "v1,AAAA")
      headers = %{headers | "webhook-signature" => bad}
      assert {:error, :no_matching_signature} = Polar.verify_webhook(payload, headers, @secret)
    end

    test "rejects a WRONG secret" do
      {headers, payload} = valid_headers()
      other = "whsec_" <> Base.encode64("a-totally-different-32-byte-keyyy")
      assert {:error, :no_matching_signature} = Polar.verify_webhook(payload, headers, other)
    end

    test "rejects an OLD timestamp (outside the 5-minute tolerance) → replay defense" do
      old = System.system_time(:second) - (5 * 60 + 1)
      {headers, payload} = valid_headers(ts: old)
      assert {:error, :timestamp_out_of_tolerance} = Polar.verify_webhook(payload, headers, @secret)
    end

    test "rejects a FUTURE timestamp outside tolerance too" do
      future = System.system_time(:second) + (5 * 60 + 1)
      {headers, payload} = valid_headers(ts: future)
      assert {:error, :timestamp_out_of_tolerance} = Polar.verify_webhook(payload, headers, @secret)
    end

    test "rejects a MISSING webhook-signature header" do
      {headers, payload} = valid_headers()
      headers = Map.delete(headers, "webhook-signature")
      assert {:error, {:missing_header, "webhook-signature"}} = Polar.verify_webhook(payload, headers, @secret)
    end

    test "rejects a missing webhook-id and a missing webhook-timestamp" do
      {headers, payload} = valid_headers()

      assert {:error, {:missing_header, "webhook-id"}} =
               Polar.verify_webhook(payload, Map.delete(headers, "webhook-id"), @secret)

      assert {:error, {:missing_header, "webhook-timestamp"}} =
               Polar.verify_webhook(payload, Map.delete(headers, "webhook-timestamp"), @secret)
    end

    test "rejects an empty / unsigned webhook-signature header" do
      {headers, payload} = valid_headers()

      for empty <- ["", "   ", "v1,"] do
        h = %{headers | "webhook-signature" => empty}
        assert match?({:error, _}, Polar.verify_webhook(payload, h, @secret)),
               "empty sig #{inspect(empty)} must fail closed"
      end
    end

    test "rejects a malformed (non-base64) secret" do
      {headers, payload} = valid_headers()
      assert {:error, :malformed_secret} = Polar.verify_webhook(payload, headers, "whsec_!!!not base64!!!")
    end

    test "rejects a non-integer timestamp" do
      {headers, payload} = valid_headers()
      headers = %{headers | "webhook-timestamp" => "not-a-number"}
      assert {:error, :bad_timestamp} = Polar.verify_webhook(payload, headers, @secret)
    end

    test "uses a CONSTANT-TIME compare — no plain == on the signature" do
      src = File.read!(Path.join([__DIR__, "..", "lib", "polar.ex"]))
      assert src =~ ":crypto.hash_equals"
      refute src =~ ~r/raw\s*==\s*expected/
      refute src =~ ~r/expected\s*==\s*raw/
    end
  end

  # ── Part B: API client ──────────────────────────────────────────────────────────

  describe "build_request/4 (pure construction, no network)" do
    test "ingest_usage targets POST /v1/events/ingest with the events envelope, NO auth header" do
      {method, url, headers, body} =
        Polar.build_request(:post, ["v1", "events", "ingest"],
          %{"events" => [%{"name" => "tok", "customer_id" => "c1"}]}, token: @token)

      assert method == :post
      assert url == "https://api.polar.sh/v1/events/ingest"
      refute Enum.any?(headers, fn {k, _} -> k == "authorization" end)
      assert {"content-type", "application/json"} in headers
      assert Jason.decode!(body) == %{"events" => [%{"name" => "tok", "customer_id" => "c1"}]}
    end

    test "ingest_usage wraps a single event into a list" do
      http = fn :post, url, _h, body ->
        assert url == "https://api.polar.sh/v1/events/ingest"
        assert Jason.decode!(body) == %{"events" => [%{"name" => "tok", "customer_id" => "c1"}]}
        {:ok, {200, ~s({"inserted":1})}}
      end

      assert {:ok, %{"inserted" => 1}} =
               Polar.ingest_usage(%{"name" => "tok", "customer_id" => "c1"}, http: http, token: @token)
    end

    test "get_subscription builds GET /v1/subscriptions/:id" do
      http = fn :get, url, _h, "" ->
        assert url == "https://api.polar.sh/v1/subscriptions/sub_123"
        {:ok, {200, ~s({"id":"sub_123","status":"active"})}}
      end

      assert {:ok, %{"id" => "sub_123", "status" => "active"}} =
               Polar.get_subscription("sub_123", http: http, token: @token)
    end

    test "checkout_link builds POST /v1/checkouts/ (trailing slash) with the body" do
      http = fn :post, url, _h, body ->
        assert url == "https://api.polar.sh/v1/checkouts/"
        assert Jason.decode!(body) == %{"products" => ["prod_1"]}
        {:ok, {201, ~s({"url":"https://buy.polar.sh/abc"})}}
      end

      assert {:ok, %{"url" => "https://buy.polar.sh/abc"}} =
               Polar.checkout_link(body: %{"products" => ["prod_1"]}, http: http, token: @token)
    end

    test "portal_link builds POST /v1/customer-sessions and yields customer_portal_url" do
      http = fn :post, url, _h, body ->
        assert url == "https://api.polar.sh/v1/customer-sessions"
        assert Jason.decode!(body) == %{"customer_id" => "cus_9"}
        {:ok, {201, ~s({"customer_portal_url":"https://polar.sh/portal/xyz"})}}
      end

      assert {:ok, %{"customer_portal_url" => "https://polar.sh/portal/xyz"}} =
               Polar.portal_link(body: %{"customer_id" => "cus_9"}, http: http, token: @token)
    end

    test "GET request carries no content-type and an empty body" do
      {_m, _u, headers, body} =
        Polar.build_request(:get, ["v1", "subscriptions", "sub_1"], nil, token: @token)

      assert body == ""
      refute Enum.any?(headers, fn {k, _} -> k == "content-type" end)
    end
  end

  describe "create_checkout/1 (dashboard wrapper)" do
    test ":not_configured without a token" do
      System.delete_env("POLAR_ACCESS_TOKEN")
      assert Polar.create_checkout(products: ["p"]) == {:error, :not_configured}
    end

    test ":no_products with an empty product list" do
      System.put_env("POLAR_ACCESS_TOKEN", @token)
      on_exit(fn -> System.delete_env("POLAR_ACCESS_TOKEN") end)
      assert Polar.create_checkout(products: []) == {:error, :no_products}
    end

    test "builds the checkout body (products + external_customer_id + metadata) and returns url/id" do
      System.put_env("POLAR_ACCESS_TOKEN", @token)
      on_exit(fn -> System.delete_env("POLAR_ACCESS_TOKEN") end)

      http = fn :post, url, _h, body ->
        assert url == "https://api.polar.sh/v1/checkouts/"
        decoded = Jason.decode!(body)
        assert decoded["products"] == ["prod_x"]
        assert decoded["external_customer_id"] == "org_42"
        assert decoded["metadata"] == %{"tenant" => "org_42", "credit" => "25.0"}
        {:ok, {201, ~s({"id":"co_1","url":"https://buy.polar.sh/z"})}}
      end

      assert {:ok, %{url: "https://buy.polar.sh/z", id: "co_1"}} =
               Polar.create_checkout(%{products: ["prod_x"], external_customer_id: "org_42",
                 metadata: %{tenant: "org_42", credit: 25.0}, http: http})
    end
  end

  describe "HTTP layer is injectable; error mapping" do
    test "non-2xx → {:error, {status, body}}, never raises" do
      http = fn _m, _u, _h, _b -> {:ok, {422, ~s({"error":"unprocessable"})}} end

      assert {:error, {422, %{"error" => "unprocessable"}}} =
               Polar.ingest_usage(%{"name" => "x", "customer_id" => "c"}, http: http, token: @token)
    end

    test "transport error is propagated as {:error, reason}" do
      http = fn _m, _u, _h, _b -> {:error, :timeout} end
      assert {:error, :timeout} = Polar.get_subscription("sub_1", http: http, token: @token)
    end
  end

  describe "id validation (SSRF / path-escape floor)" do
    test "a slash / dot-segment / query char in a subscription id fails closed" do
      http = fn _m, _u, _h, _b -> flunk("should not have dispatched") end

      for bad <- ["../other", "a/b", "..", "a?x=1", "a#frag", "a b", ""] do
        assert {:error, :invalid_id} = Polar.get_subscription(bad, http: http)
      end
    end

    test "api host is one of the two fixed constants, never caller-supplied" do
      assert Polar.api_host() in ["https://api.polar.sh", "https://sandbox-api.polar.sh"]
    end
  end

  describe "token never leaks" do
    test "token absent from every returned value (ok, error, transport-error, invalid)" do
      System.put_env("POLAR_ACCESS_TOKEN", @token)
      on_exit(fn -> System.delete_env("POLAR_ACCESS_TOKEN") end)

      results = [
        Polar.ingest_usage(%{"name" => "x", "customer_id" => "c"}, http: fn _, _, _, _ -> {:ok, {200, "{}"}} end),
        Polar.get_subscription("sub_1", http: fn _, _, _, _ -> {:ok, {500, ~s({"e":"boom"})}} end),
        Polar.get_subscription("sub_1", http: fn _, _, _, _ -> {:error, :nxdomain} end),
        Polar.get_subscription("../bad", http: fn _, _, _, _ -> :ok end)
      ]

      for r <- results do
        refute inspect(r) =~ @token
        refute inspect(r) =~ "Bearer"
      end
    end

    test "build_request output contains no token at all (url, headers, body)" do
      tuple = Polar.build_request(:post, ["v1", "events", "ingest"], %{"k" => "v"}, token: @token)
      refute inspect(tuple) =~ @token
      refute inspect(tuple) =~ "Bearer"
      refute inspect(tuple) =~ "authorization"
    end
  end

  describe "TLS is verified (no MITM of the Polar access token)" do
    test "http_options pin verify_peer, a non-empty CA store, and the host SNI" do
      opts = Polar.http_options()
      ssl = Keyword.fetch!(opts, :ssl)

      assert Keyword.get(ssl, :verify) == :verify_peer
      cacerts = Keyword.get(ssl, :cacerts)
      assert is_list(cacerts) and cacerts != []
      assert Keyword.get(ssl, :server_name_indication) == ~c"api.polar.sh"
      assert Keyword.has_key?(ssl, :customize_hostname_check)
    end
  end

  describe "entitlements/1 (pure mapping; fail closed)" do
    test "active subscription → can_provision with tier limits" do
      ent = Polar.entitlements(%{"status" => "active", "product" => %{"name" => "Pro plan"}})
      assert ent.can_provision == true
      assert ent.max_nexuses == 10
      assert ent.seats == 10
      assert ent.storage_quota_bytes > 0
    end

    test "active enterprise tier gets the largest limits" do
      ent = Polar.entitlements(%{"status" => "active", "plan" => "Enterprise"})
      assert ent.can_provision == true
      assert ent.max_nexuses == 100
    end

    test "active unknown/free plan still provisions one nexus" do
      ent = Polar.entitlements(%{"status" => "active", "product" => %{"name" => "Hobby"}})
      assert ent.can_provision == true
      assert ent.max_nexuses == 1
    end

    test "canceled → can_provision false with zeroed limits (fail closed)" do
      ent = Polar.entitlements(%{"status" => "canceled", "product" => %{"name" => "Pro"}})

      assert ent == %{can_provision: false, max_nexuses: 0, seats: 0, storage_quota_bytes: 0,
               phone_channel: false, phone_numbers: 0}
    end

    test "phone channel (wb-h0pey): paid tiers get it, free does not, lapsed loses it" do
      assert %{phone_channel: true, phone_numbers: 3} =
               Polar.entitlements(%{"status" => "active", "plan" => "pro"})

      assert %{phone_channel: true, phone_numbers: 1} =
               Polar.entitlements(%{"status" => "active", "plan" => "starter"})

      assert %{phone_channel: false, phone_numbers: 0} =
               Polar.entitlements(%{"status" => "active", "product" => %{"name" => "Hobby"}})

      assert %{phone_channel: false, phone_numbers: 0} =
               Polar.entitlements(%{"status" => "past_due", "plan" => "pro"})
    end

    test "past_due → can_provision false even on a paid tier (fail closed)" do
      ent = Polar.entitlements(%{"status" => "past_due", "plan" => "enterprise"})
      assert ent.can_provision == false
      assert ent.max_nexuses == 0
    end

    test "missing status / non-map → fail closed" do
      assert %{can_provision: false} = Polar.entitlements(%{"product" => %{"name" => "Pro"}})
      assert %{can_provision: false} = Polar.entitlements(nil)
    end
  end
end
