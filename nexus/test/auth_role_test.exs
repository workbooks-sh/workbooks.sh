defmodule Nexus.AuthRoleTest do
  use ExUnit.Case, async: true
  alias Nexus.Auth

  test "role/1 is server-derived from identity, defaults to least privilege" do
    assert Auth.role(%{assigns: %{}}) == "viewer"
    assert Auth.role(%{assigns: %{identity: %{roles: ["member", "admin"]}}}) == "admin"
    assert Auth.role(%{assigns: %{identity: %{roles: ["owner"]}}}) == "owner"
    assert Auth.role(%{assigns: %{identity: %{roles: []}}}) == "viewer"
  end

  test "role_at_least? ranks viewer<member<admin<owner" do
    assert Auth.role_at_least?("admin", "admin")
    assert Auth.role_at_least?("owner", "admin")
    refute Auth.role_at_least?("member", "admin")
    refute Auth.role_at_least?("viewer", "admin")
  end
end
