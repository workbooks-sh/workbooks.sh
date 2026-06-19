defmodule Nexus.Auth.ProviderTest do
  use ExUnit.Case, async: false
  alias Nexus.Auth.Provider
  import Plug.Test
  import Plug.Conn

  @cfg ~S"""
  deploy do
    auth-provider-acme-authorize-url="https://idp.acme.com/authorize"
    auth-provider-acme-token-url="https://idp.acme.com/token"
    auth-provider-acme-client-id="client-123"
    auth-provider-acme-redirect-uri="https://app.example.com/auth/acme/callback"
    auth-provider-acme-scope="openid email"
    auth-provider-insecure-authorize-url="http://idp.bad.com/authorize"
  end
  """

  setup do
    Nexus.Config.reload(@cfg)
    on_exit(&Nexus.Config.boot/0)
    :ok
  end

  test "Config parses auth-provider-<name>-<key> into a provider map" do
    p = Nexus.Config.provider("acme")
    assert p["authorize-url"] == "https://idp.acme.com/authorize"
    assert p["client-id"] == "client-123"
    assert Nexus.Config.provider("acme", "scope") == "openid email"
    assert Nexus.Config.provider("nope") == %{}
  end

  test "unknown provider → 404" do
    conn = Provider.login(conn(:get, "/auth/nope/login"), "nope")
    assert conn.status == 404
  end

  test "SECURITY: a non-https authorize-url is refused (no cleartext MITM)" do
    conn = Provider.login(conn(:get, "/auth/insecure/login"), "insecure")
    assert conn.status == 500
  end

  test "login 302-redirects to the provider with the OAuth params" do
    conn = Provider.login(conn(:get, "/auth/acme/login"), "acme")
    assert conn.status == 302
    [loc] = get_resp_header(conn, "location")
    assert String.starts_with?(loc, "https://idp.acme.com/authorize?")
    assert loc =~ "response_type=code"
    assert loc =~ "client_id=client-123"
    assert loc =~ "scope=openid+email"
    assert loc =~ URI.encode_www_form("https://app.example.com/auth/acme/callback")
    assert loc =~ ~r/state=[\w-]+/
    assert loc =~ ~r/nonce=[\w-]+/
  end

  test "login sets a signed, httpOnly, SameSite state cookie" do
    conn = Provider.login(conn(:get, "/auth/acme/login"), "acme")
    [cookie] = get_resp_header(conn, "set-cookie")
    assert cookie =~ "wb_oauth_state="
    assert cookie =~ "HttpOnly"
    assert cookie =~ ~r/SameSite=Lax/i
  end

  test "state cookie round-trips through verify_state; tamper/absence → :error" do
    conn = Provider.login(conn(:get, "/auth/acme/login"), "acme")
    [setc] = get_resp_header(conn, "set-cookie")
    cookie = setc |> String.split(";") |> hd()

    # the state in the cookie must match the state in the redirect (CSRF anchor)
    [loc] = get_resp_header(conn, "location")
    state_in_url = URI.decode_query(URI.parse(loc).query)["state"]

    back = %{conn(:get, "/auth/acme/callback") | req_headers: [{"cookie", cookie}]}
    assert {:ok, %{s: ^state_in_url, n: _nonce, p: "acme"}} = Provider.verify_state(back)

    tampered = %{conn(:get, "/cb") | req_headers: [{"cookie", cookie <> "x"}]}
    assert Provider.verify_state(tampered) == :error
    assert Provider.verify_state(conn(:get, "/cb")) == :error
  end
end
