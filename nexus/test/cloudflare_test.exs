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
end
