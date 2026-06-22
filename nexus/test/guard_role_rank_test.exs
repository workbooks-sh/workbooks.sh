defmodule Nexus.Auth.GuardRoleRankTest do
  @moduledoc """
  wb-i04g: a `protect role: "admin"` rule must be RANK-based (viewer<member<admin<owner), like every
  other role gate in the system — an OWNER satisfies an admin requirement. The old `r in roles` exact
  match would deny an owner, contradicting Nexus.Authz/Nexus.Auth.role_at_least?.
  """
  use ExUnit.Case, async: false
  alias Nexus.Auth.Guard

  setup do
    Guard.protect("/admin/**", role: "admin")
    on_exit(&Guard.reset/0)
    :ok
  end

  test "owner (rank above admin) is allowed through an admin-protected path" do
    assert Guard.decide("GET", "/admin/x", %{tenant: "t", roles: ["owner"]}) == :allow
  end

  test "admin is allowed" do
    assert Guard.decide("GET", "/admin/x", %{tenant: "t", roles: ["admin"]}) == :allow
  end

  test "member (below admin) is forbidden" do
    assert Guard.decide("GET", "/admin/x", %{tenant: "t", roles: ["member"]}) == :forbidden
  end

  test "unauthenticated needs login" do
    assert Guard.decide("GET", "/admin/x", %{}) == :unauthenticated
  end
end
