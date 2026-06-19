defmodule Nexus.Auth.SessionTest do
  use ExUnit.Case, async: false
  alias Nexus.Auth.Session
  import Plug.Test
  import Plug.Conn

  @identity %{tenant: "org1", user: "u1", roles: ["admin"], scopes: ["read"]}

  defp issued_conn(identity \\ @identity, opts \\ []) do
    conn = issue_into(conn(:get, "/"), identity, opts)
    [cookie] = get_resp_header(conn, "set-cookie")
    # carry the cookie into a fresh request
    %{conn(:get, "/") | req_headers: [{"cookie", String.split(cookie, ";") |> hd()}]}
  end

  defp issue_into(conn, identity, opts), do: conn |> Session.issue(identity, opts) |> resp(200, "") |> send_resp()

  test "issue → verify round-trips the identity" do
    assert {:ok, id} = Session.verify(issued_conn())
    assert id.tenant == "org1"
    assert id.roles == ["admin"]
    refute Map.has_key?(id, :iat)
  end

  test "cookie is httpOnly + SameSite (XSS/CSRF hardening)" do
    conn = issue_into(conn(:get, "/"), @identity, [])
    [cookie] = get_resp_header(conn, "set-cookie")
    assert cookie =~ "HttpOnly"
    assert cookie =~ ~r/SameSite=Lax/i
    assert cookie =~ "wb_session="
  end

  test "a tampered cookie is rejected" do
    conn = issued_conn()
    [{"cookie", c}] = conn.req_headers
    tampered = %{conn | req_headers: [{"cookie", c <> "x"}]}
    assert Session.verify(tampered) == :error
  end

  test "no cookie ⇒ :error" do
    assert Session.verify(conn(:get, "/")) == :error
  end

  test "expired session is rejected" do
    # verify() checks the token's signed age against Config.session_max_age. Sign now, set max_age=1,
    # sleep past it → the signature is too old → :error.
    Nexus.Config.put(:session_max_age, 1)
    on_exit(fn -> Nexus.Config.boot() end)
    conn = issued_conn(@identity)
    Process.sleep(1200)
    assert Session.verify(conn) == :error
  end

  test "renew signal past half-life" do
    # renew fires when age is in (half-life, max_age). max_age 6 → half-life 3; sleeping ~4.5s lands
    # age at 4–5s (well inside the window despite integer-second granularity), and NOT past max_age.
    Nexus.Config.put(:session_max_age, 6)
    on_exit(fn -> Nexus.Config.boot() end)
    conn = issued_conn(@identity, max_age: 6)
    Process.sleep(4500)
    assert match?({:ok, _, :renew}, Session.verify(conn))
  end

  test "Cookie adapter authenticates from a valid session, rejects without" do
    assert {:ok, id} = Nexus.Auth.Cookie.authenticate(issued_conn())
    assert id.tenant == "org1"
    assert {:error, _} = Nexus.Auth.Cookie.authenticate(conn(:get, "/"))
  end
end
