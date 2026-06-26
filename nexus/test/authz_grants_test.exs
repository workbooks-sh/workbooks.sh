defmodule Nexus.Authz.GrantsTest do
  @moduledoc "Persisted workspace roles + capability grants with separation of duties."
  use ExUnit.Case, async: false
  alias Nexus.Authz.Grants
  alias Nexus.ControlPlane, as: CP

  @org "org_g"
  @admin %{user: "ada", role: "admin"}
  @owner %{user: "odin", role: "owner"}
  @member %{user: "mel", role: "member"}

  setup do
    CP.reset()
    :ok
  end

  describe "workspace roles" do
    test "an admin can assign a member role; role_in resolves the override" do
      assert {:ok, _} = Grants.assign_role(@org, "ws1", "bob", "member", @admin)
      assert Grants.role_in(@org, "ws1", "bob") == "member"
      # no override in a different workspace → falls back to the passed org role
      assert Grants.role_in(@org, "ws2", "bob", "viewer") == "viewer"
    end

    test "may_in? gates on the workspace role, not the org role" do
      Grants.assign_role(@org, "ws1", "bob", "admin", @owner)
      assert Grants.may_in?(@org, "ws1", "bob", :manage, "viewer")
      refute Grants.may_in?(@org, "ws2", "bob", :manage, "viewer")
    end

    test "roster lists a workspace's overrides only" do
      Grants.assign_role(@org, "ws1", "bob", "member", @admin)
      Grants.assign_role(@org, "ws2", "cat", "member", @admin)
      assert Enum.map(Grants.roster(@org, "ws1"), & &1.user) == ["bob"]
    end
  end

  describe "separation of duties" do
    test "a member (not admin) cannot assign roles" do
      assert {:error, :not_an_admin} = Grants.assign_role(@org, "ws1", "bob", "member", @member)
    end

    test "an admin cannot mint an owner (grant above self)" do
      assert {:error, :grant_above_self} = Grants.assign_role(@org, "ws1", "bob", "owner", @admin)
      # but an owner can
      assert {:ok, _} = Grants.assign_role(@org, "ws1", "bob", "owner", @owner)
    end

    test "no self-escalation — you can't promote yourself above your current role" do
      # ada is admin; tries to make herself owner
      assert {:error, :self_escalation} = Grants.assign_role(@org, "ws1", "ada", "owner", @admin)
    end

    test "assigning yourself an equal/lower role is fine" do
      assert {:ok, _} = Grants.assign_role(@org, "ws1", "ada", "admin", @admin)
    end
  end

  describe "capability grants" do
    test "grant + granted? + grants_for" do
      assert {:ok, _} = Grants.grant(@org, "ws1", "agent:helper", "net", @admin)
      assert Grants.granted?(@org, "ws1", "agent:helper", "net")
      refute Grants.granted?(@org, "ws1", "agent:helper", "exec")
      assert Enum.map(Grants.grants_for(@org, "agent:helper"), & &1.capability) == ["net"]
    end

    test "an expired grant is not held and not listed" do
      past = System.os_time(:millisecond) - 1000
      Grants.grant(@org, "ws1", "u:bob", "secrets", @admin, expires_at: past)
      refute Grants.granted?(@org, "ws1", "u:bob", "secrets")
      assert Grants.grants_for(@org, "u:bob") == []
    end

    test "revoke removes a grant" do
      Grants.grant(@org, "ws1", "u:bob", "kv", @admin)
      assert Grants.granted?(@org, "ws1", "u:bob", "kv")
      Grants.revoke(@org, "ws1", "u:bob", "kv")
      refute Grants.granted?(@org, "ws1", "u:bob", "kv")
    end

    test "a non-admin cannot grant" do
      assert {:error, :not_an_admin} = Grants.grant(@org, "ws1", "u:bob", "net", @member)
    end
  end

  test "grants are org-isolated (no cross-org leak)" do
    Grants.grant(@org, "ws1", "u:bob", "net", @admin)
    refute Grants.granted?("org_other", "ws1", "u:bob", "net")
  end
end
