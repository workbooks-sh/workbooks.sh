defmodule Nexus.Auth.GuardTest do
  use ExUnit.Case, async: false
  alias Nexus.Auth.Guard

  @admin %{tenant: "org1", user: "u1", roles: ["admin"], scopes: ["read", "write"]}
  @member %{tenant: "org1", user: "u2", roles: ["member"], scopes: ["read"]}
  @anon %{tenant: ""}

  setup do
    Guard.reset()
    on_exit(&Guard.reset/0)
    :ok
  end

  test "BACKWARD-COMPAT: no auth declared ⇒ everything is allowed (no behavior change)" do
    refute Guard.declared?()
    assert Guard.decide("GET", "/admin/x", @anon) == :allow
    assert Guard.decide("POST", "/anything", nil) == :allow
  end

  test "declaring flips to default-deny: unmatched path needs authentication" do
    Guard.declare()
    assert Guard.decide("GET", "/whatever", @member) == :allow
    assert Guard.decide("GET", "/whatever", @anon) == :unauthenticated
  end

  test "public rule allows without authentication" do
    Guard.public(["/", "/pricing"])
    assert Guard.decide("GET", "/", @anon) == :allow
    assert Guard.decide("GET", "/pricing", nil) == :allow
    # a non-public path is still default-deny once declared
    assert Guard.decide("GET", "/dashboard", @anon) == :unauthenticated
  end

  test "role guard: 403 when authenticated but missing the role, allow with it" do
    Guard.protect("/admin/**", role: "admin")
    assert Guard.decide("GET", "/admin/settings", @admin) == :allow
    assert Guard.decide("GET", "/admin/settings", @member) == :forbidden
    # unauthenticated → needs login, not 403
    assert Guard.decide("GET", "/admin/settings", @anon) == :unauthenticated
  end

  test "scope guard with method binding" do
    Guard.protect("POST /api/**", scope: "write")
    assert Guard.decide("POST", "/api/orders", @admin) == :allow
    assert Guard.decide("POST", "/api/orders", @member) == :forbidden
    # GET isn't bound by this POST guard → default-deny (authenticated ok)
    assert Guard.decide("GET", "/api/orders", @member) == :allow
  end

  test "most-specific guard wins (literal beats wildcard)" do
    Guard.protect("/api/**", role: "member")
    Guard.protect("/api/admin/**", role: "admin")
    assert Guard.decide("GET", "/api/admin/x", @member) == :forbidden
    assert Guard.decide("GET", "/api/admin/x", @admin) == :allow
    assert Guard.decide("GET", "/api/public", @member) == :allow
  end

  test "glob matching: **, :param, exact" do
    Guard.protect("/u/:id/edit", role: "admin")
    assert Guard.decide("GET", "/u/42/edit", @member) == :forbidden
    assert Guard.decide("GET", "/u/42/edit", @admin) == :allow
    assert Guard.decide("GET", "/u/42/view", @member) == :allow
  end

  test "fail-closed: an authenticated user with NO roles is denied a role-guarded route" do
    Guard.protect("/admin/**", role: "admin")
    assert Guard.decide("GET", "/admin/x", %{tenant: "org1", user: "u"}) == :forbidden
  end

  test "parse splits method/path, defaults :any" do
    assert Guard.parse("GET /a/b") == {"GET", "/a/b"}
    assert Guard.parse("/a/b") == {:any, "/a/b"}
    assert Guard.parse("post /x") == {"POST", "/x"}
  end
end
