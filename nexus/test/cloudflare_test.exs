defmodule Nexus.CloudflareTest do
  use ExUnit.Case, async: true

  # Without a CLOUDFLARE_API_TOKEN secret, every call must skip (→ fall back to the Fly-cert path),
  # never error, never touch the network. (No token is set in the test env.)
  test "unconfigured → {:skip, _}" do
    assert {:skip, _} = Nexus.Cloudflare.create_custom_hostname("app.customer.com", zone: "z1")
    refute Nexus.Cloudflare.configured?()
  end

  defp capture(reply) do
    {:ok, agent} = Agent.start_link(fn -> nil end)
    http = fn method, url, headers, body ->
      Agent.update(agent, fn _ -> %{method: method, url: url, headers: headers, body: body} end)
      reply
    end
    {agent, http}
  end

  test "create_custom_hostname posts to the zone endpoint with DV ssl + bearer token" do
    ok = Jason.encode!(%{"success" => true, "result" => %{"id" => "ch1", "ssl" => %{"status" => "pending_validation"}}})
    {agent, http} = capture({:ok, {200, ok}})

    assert {:ok, %{"id" => "ch1"}} =
             Nexus.Cloudflare.create_custom_hostname("app.customer.com", zone: "zoneA", token: "cf_tok", http: http)

    sent = Agent.get(agent, & &1)
    assert sent.method == :post
    assert sent.url == "https://api.cloudflare.com/client/v4/zones/zoneA/custom_hostnames"
    # Token is added ONLY in the real :httpc transport (injected http bypasses it) — never leaked into
    # the pure request shape the test sees.
    refute Enum.any?(sent.headers, fn {k, _} -> String.downcase(k) == "authorization" end)
    body = Jason.decode!(sent.body)
    assert body["hostname"] == "app.customer.com"
    assert body["ssl"]["type"] == "dv"
    assert body["ssl"]["method"] == "http"
  end

  test "get + delete hit the right url" do
    {agent, http} = capture({:ok, {200, Jason.encode!(%{"success" => true, "result" => %{"id" => "ch1"}})}})
    assert {:ok, %{"id" => "ch1"}} = Nexus.Cloudflare.get_custom_hostname("ch1", zone: "z", token: "t", http: http)
    assert Agent.get(agent, & &1).url == "https://api.cloudflare.com/client/v4/zones/z/custom_hostnames/ch1"

    {agent2, http2} = capture({:ok, {200, Jason.encode!(%{"success" => true, "result" => %{"id" => "ch1"}})}})
    assert {:ok, _} = Nexus.Cloudflare.delete_custom_hostname("ch1", zone: "z", token: "t", http: http2)
    assert Agent.get(agent2, & &1).method == :delete
  end

  test "a CF-level failure (success:false) returns {:error, {:cf_error, _}}" do
    body = Jason.encode!(%{"success" => false, "errors" => [%{"code" => 1234, "message" => "bad"}]})
    {_a, http} = capture({:ok, {200, body}})
    assert {:error, {:cf_error, [%{"message" => "bad"}]}} =
             Nexus.Cloudflare.create_custom_hostname("x.com", zone: "z", token: "t", http: http)
  end

  test "a non-2xx returns {:error, {:cf_http, status, _}}" do
    {_a, http} = capture({:ok, {403, Jason.encode!(%{"errors" => [%{"message" => "forbidden"}]})}})
    assert {:error, {:cf_http, 403, _}} =
             Nexus.Cloudflare.get_custom_hostname("ch1", zone: "z", token: "t", http: http)
  end

  # ── DNS records + Email Routing (the agent-email / custom-domain seam) ───────────────────────────

  # A transport that answers per (method, url) and records every call in order.
  defp router(reply_fun) do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    http = fn method, url, headers, body ->
      Agent.update(agent, fn calls -> calls ++ [%{method: method, url: url, headers: headers, body: body}] end)
      reply_fun.(method, url)
    end

    {agent, http}
  end

  defp ok_result(result), do: {:ok, {200, Jason.encode!(%{"success" => true, "result" => result})}}

  test "DNS calls skip when unconfigured (no token) — never touch the network" do
    assert {:skip, _} = Nexus.Cloudflare.create_dns_record(%{"type" => "TXT", "name" => "x", "content" => "y"})
  end

  test "create_dns_record maps value→content, defaults ttl, whitelists keys, posts to dns_records" do
    {agent, http} = router(fn _m, _u -> ok_result(%{"id" => "r1"}) end)

    assert {:ok, %{"id" => "r1"}} =
             Nexus.Cloudflare.create_dns_record(
               %{"type" => "MX", "name" => "agents.workbooks.sh", "value" => "mx.relay.com",
                 "priority" => 10, "status" => "MISSING"},
               zone: "zoneA", token: "t", http: http
             )

    [call] = Agent.get(agent, & &1)
    assert call.method == :post
    assert call.url == "https://api.cloudflare.com/client/v4/zones/zoneA/dns_records"
    body = Jason.decode!(call.body)
    assert body["content"] == "mx.relay.com"
    assert body["priority"] == 10
    assert body["ttl"] == 1
    refute Map.has_key?(body, "value")
    refute Map.has_key?(body, "status")
  end

  test "list_dns_records puts the filter on the query string" do
    {agent, http} = router(fn _m, _u -> ok_result([]) end)

    assert {:ok, []} =
             Nexus.Cloudflare.list_dns_records(zone: "z", token: "t", http: http, filter: %{"type" => "TXT"})

    [call] = Agent.get(agent, & &1)
    assert call.method == :get
    assert String.contains?(call.url, "/zones/z/dns_records?")
    assert String.contains?(call.url, "type=TXT")
  end

  test "upsert creates when absent and updates in place when present (idempotent by type+name)" do
    {a1, http1} =
      router(fn
        :get, _ -> ok_result([])
        :post, _ -> ok_result(%{"id" => "new"})
      end)

    assert {:ok, %{"id" => "new"}} =
             Nexus.Cloudflare.upsert_dns_record(%{"type" => "TXT", "name" => "n", "content" => "c"},
               zone: "z", token: "t", http: http1)

    assert Enum.map(Agent.get(a1, & &1), & &1.method) == [:get, :post]

    {a2, http2} =
      router(fn
        :get, _ -> ok_result([%{"id" => "rec1", "type" => "TXT", "name" => "n"}])
        :put, _ -> ok_result(%{"id" => "rec1"})
      end)

    assert {:ok, %{"id" => "rec1"}} =
             Nexus.Cloudflare.upsert_dns_record(%{"type" => "TXT", "name" => "n", "content" => "c2"},
               zone: "z", token: "t", http: http2)

    calls2 = Agent.get(a2, & &1)
    assert Enum.map(calls2, & &1.method) == [:get, :put]
    assert List.last(calls2).url == "https://api.cloudflare.com/client/v4/zones/z/dns_records/rec1"
  end

  test "delete_dns_record fails closed on an unsafe id (never calls the transport)" do
    assert {:error, :invalid_id} =
             Nexus.Cloudflare.delete_dns_record("../rules",
               zone: "z", token: "t", http: fn _, _, _, _ -> flunk("must not reach the network") end)
  end

  # ── Edge-app ops (wb-jr1py.2: purge / workers / r2 / pages) ──────────────────────────────────────

  test "purge_cache defaults to purge_everything; opts[:files] purges just those URLs" do
    {a, http} = router(fn _m, _u -> ok_result(%{"id" => "z"}) end)
    assert {:ok, _} = Nexus.Cloudflare.purge_cache(zone: "z", token: "t", http: http)
    call = List.last(Agent.get(a, & &1))
    assert call.method == :post
    assert call.url == "https://api.cloudflare.com/client/v4/zones/z/purge_cache"
    assert Jason.decode!(call.body) == %{"purge_everything" => true}

    {a2, http2} = router(fn _m, _u -> ok_result(%{"id" => "z"}) end)
    files = ["https://workbooks.sh/lander/", "https://workbooks.sh/docs/"]
    assert {:ok, _} = Nexus.Cloudflare.purge_cache(zone: "z", token: "t", http: http2, files: files)
    assert Jason.decode!(List.last(Agent.get(a2, & &1)).body) == %{"files" => files}
  end

  test "account-scoped ops skip without an account id (token present) — never touch the network" do
    http = fn _, _, _, _ -> flunk("must not reach the network") end
    assert {:skip, reason} = Nexus.Cloudflare.list_r2_buckets(token: "t", http: http)
    assert reason =~ "account id"
  end

  test "upload_worker PUTs an ES-module multipart to the account scripts endpoint" do
    {a, http} = router(fn _m, _u -> ok_result(%{"id" => "app-shell"}) end)

    assert {:ok, _} =
             Nexus.Cloudflare.upload_worker("app-shell", "export default {};",
               account: "acct1", token: "t", http: http,
               metadata: %{"compatibility_date" => "2026-07-01"}
             )

    [call] = Agent.get(a, & &1)
    assert call.method == :put
    assert call.url == "https://api.cloudflare.com/client/v4/accounts/acct1/workers/scripts/app-shell"
    {_, ct} = Enum.find(call.headers, fn {k, _} -> String.downcase(k) == "content-type" end)
    assert ct =~ "multipart/form-data; boundary="
    assert call.body =~ ~s("main_module":"worker.js")
    assert call.body =~ ~s("compatibility_date":"2026-07-01")
    assert call.body =~ "export default {};"
    assert call.body =~ "Content-Type: application/javascript+module"
  end

  test "upload_worker fails closed on an unsafe script name" do
    assert {:error, :invalid_id} =
             Nexus.Cloudflare.upload_worker("../evil", "x",
               account: "a", token: "t", http: fn _, _, _, _ -> flunk("must not reach the network") end)
  end

  test "r2 bucket + pages project ops hit the account endpoints" do
    {a, http} = router(fn _m, _u -> ok_result(%{"name" => "media"}) end)
    assert {:ok, _} = Nexus.Cloudflare.create_r2_bucket("media", account: "acct1", token: "t", http: http)
    call = List.last(Agent.get(a, & &1))
    assert call.url == "https://api.cloudflare.com/client/v4/accounts/acct1/r2/buckets"
    assert Jason.decode!(call.body) == %{"name" => "media"}

    {a2, http2} = router(fn _m, _u -> ok_result(%{"name" => "my-app"}) end)
    assert {:ok, _} = Nexus.Cloudflare.create_pages_project("my-app", account: "acct1", token: "t", http: http2)
    call2 = List.last(Agent.get(a2, & &1))
    assert call2.url == "https://api.cloudflare.com/client/v4/accounts/acct1/pages/projects"
    assert Jason.decode!(call2.body) == %{"name" => "my-app", "production_branch" => "main"}

    {a3, http3} = router(fn _m, _u -> ok_result(nil) end)
    assert {:ok, _} = Nexus.Cloudflare.delete_r2_bucket("media", account: "acct1", token: "t", http: http3)
    assert List.last(Agent.get(a3, & &1)).method == :delete
  end

  test "create_worker_route posts pattern+script on the zone" do
    {a, http} = router(fn _m, _u -> ok_result(%{"id" => "route1"}) end)

    assert {:ok, _} =
             Nexus.Cloudflare.create_worker_route("app.example.com/*", "app-shell",
               zone: "z", token: "t", http: http)

    call = List.last(Agent.get(a, & &1))
    assert call.url == "https://api.cloudflare.com/client/v4/zones/z/workers/routes"
    assert Jason.decode!(call.body) == %{"pattern" => "app.example.com/*", "script" => "app-shell"}
  end

  test "enable_email_routing + catch-all→worker hit the right endpoints with the right body" do
    {a, http} = router(fn _m, _u -> ok_result(%{"status" => "ready"}) end)
    assert {:ok, _} = Nexus.Cloudflare.enable_email_routing(zone: "z", token: "t", http: http)
    assert List.last(Agent.get(a, & &1)).url == "https://api.cloudflare.com/client/v4/zones/z/email/routing/enable"

    {a2, http2} = router(fn _m, _u -> ok_result(%{"id" => "catch_all"}) end)
    assert {:ok, _} = Nexus.Cloudflare.set_email_catch_all("email-ingress", zone: "z", token: "t", http: http2)

    call = List.last(Agent.get(a2, & &1))
    assert call.method == :put
    assert call.url == "https://api.cloudflare.com/client/v4/zones/z/email/routing/rules/catch_all"
    body = Jason.decode!(call.body)
    assert body["actions"] == [%{"type" => "worker", "value" => ["email-ingress"]}]
    assert body["matchers"] == [%{"type" => "all"}]
  end
end
