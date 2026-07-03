defmodule Nexus.Cloud.ComposioTest do
  use ExUnit.Case, async: false
  alias Nexus.Cloud.Composio

  setup do
    System.delete_env("COMPOSIO_API_KEY")
    :ok
  end

  test "no-op-safe: absent key AND no injected transport → {:skip, :composio_not_configured}" do
    assert Composio.list_toolkits() == {:skip, :composio_not_configured}
    assert Composio.connect("u1", "ac_1") == {:skip, :composio_not_configured}
    assert Composio.mcp_url("u1", ["github"]) == {:skip, :composio_not_configured}
  end

  test "the x-api-key + accept headers are added by the transport, not the pure body" do
    parent = self()

    http = fn _m, _url, headers, _body ->
      send(parent, {:headers, headers})
      {:ok, {200, ~s([])}}
    end

    # opts[:http] present ⇒ ready; the key never appears in headers passed to the injected transport
    # (it is added only inside the real do_request), so the injected stub sees just accept/content-type.
    {:ok, _} = Composio.list_toolkits(http: http, api_key: "k")
    assert_receive {:headers, headers}
    assert Enum.any?(headers, fn {k, _} -> k == "accept" end)
    refute Enum.any?(headers, fn {k, _} -> k == "x-api-key" end)
  end

  test "list_toolkits decodes the payload" do
    http = fn :get, url, _h, _b ->
      assert String.ends_with?(url, "/toolkits")
      {:ok, {200, ~s({"items":[{"slug":"github"},{"slug":"gmail"}]})}}
    end

    assert {:ok, %{"items" => [%{"slug" => "github"} | _]}} = Composio.list_toolkits(http: http, api_key: "k")
  end

  test "create_auth_config builds the whitelabel (use_custom_auth) body and returns ac_…" do
    parent = self()

    http = fn :post, url, _h, body ->
      assert String.ends_with?(url, "/auth_configs")
      send(parent, {:body, Jason.decode!(body)})
      {:ok, {201, ~s({"id":"ac_123"})}}
    end

    creds = %{client_id: "cid", client_secret: "sec", redirect_uri: "https://us/cb"}
    assert {:ok, %{"id" => "ac_123"}} = Composio.create_auth_config("github", creds, http: http, api_key: "k")

    assert_receive {:body, b}
    assert b["toolkit"] == "github"
    assert b["options"]["type"] == "use_custom_auth"
    assert b["options"]["auth_scheme"] == "OAUTH2"
    assert b["options"]["credentials"]["client_id"] == "cid"
    assert b["options"]["credentials"]["oauth_redirect_uri"] == "https://us/cb"
  end

  test "connect posts the user_id + auth_config and returns a redirect_url" do
    parent = self()

    http = fn :post, url, _h, body ->
      assert String.ends_with?(url, "/connected_accounts")
      send(parent, {:body, Jason.decode!(body)})
      {:ok, {200, ~s({"id":"conn_1","redirect_url":"https://consent/x"})}}
    end

    assert {:ok, %{"redirect_url" => "https://consent/x"}} =
             Composio.connect("tenant-9", "ac_123", http: http, api_key: "k", callback_url: "https://us/done")

    assert_receive {:body, b}
    assert b["auth_config"]["id"] == "ac_123"
    assert b["connection"]["user_id"] == "tenant-9"
    assert b["connection"]["state"]["authScheme"] == "OAUTH2"
    assert b["connection"]["callback_url"] == "https://us/done"
  end

  test "connection_status polls the account and surfaces ACTIVE" do
    http = fn :get, url, _h, _b ->
      assert String.ends_with?(url, "/connected_accounts/conn_1")
      {:ok, {200, ~s({"id":"conn_1","status":"ACTIVE"})}}
    end

    assert {:ok, %{"status" => "ACTIVE"}} = Composio.connection_status("conn_1", http: http, api_key: "k")
  end

  test "mcp_url creates the server then formats the per-user URL" do
    http = fn :post, url, _h, _b ->
      assert String.ends_with?(url, "/mcp/servers")
      {:ok, {200, ~s({"id":"srv_abc"})}}
    end

    assert {:ok, url} = Composio.mcp_url("tenant 9", ["github", "gmail"], http: http, api_key: "k")
    assert url == "https://backend.composio.dev/v3/mcp/srv_abc?user_id=tenant+9"
  end

  test "a non-2xx becomes {:error, {status, body}}" do
    http = fn _m, _url, _h, _b -> {:ok, {401, ~s({"error":"bad key"})}} end
    assert {:error, {401, %{"error" => "bad key"}}} = Composio.list_toolkits(http: http, api_key: "k")
  end
end
