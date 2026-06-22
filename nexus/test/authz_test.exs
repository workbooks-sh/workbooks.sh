defmodule Nexus.AuthzTest do
  @moduledoc """
  wb-h88g: the authorization layer. Identity answers WHO; Authz answers what they MAY do — a tiny,
  auditable pair of pure predicates the whole app gates through (route role-gating + per-workspace
  visibility). Reuses Nexus.Auth's role rank; fail-closed on anything unknown.
  """
  use ExUnit.Case, async: true
  alias Nexus.Authz

  describe "may?/2 — role meets the action's minimum" do
    test "read needs viewer, write needs member, manage needs admin, own needs owner" do
      assert Authz.may?("viewer", :read)
      refute Authz.may?("viewer", :write)
      assert Authz.may?("member", :write)
      refute Authz.may?("member", :manage)
      assert Authz.may?("admin", :manage)
      refute Authz.may?("admin", :own)
      assert Authz.may?("owner", :own)
    end

    test "higher roles inherit lower actions" do
      assert Authz.may?("owner", :read)
      assert Authz.may?("admin", :write)
    end

    test "unknown action / blank role fails closed" do
      refute Authz.may?("owner", :nonsense)
      refute Authz.may?("", :read)
      refute Authz.may?(nil, :read)
    end
  end

  describe "may_access?/4 — visibility + ownership" do
    test "public: anyone reads; writing needs member" do
      assert Authz.may_access?(%{role: "viewer", user: "a@x"}, "public", "b@x", :read)
      refute Authz.may_access?(%{role: "viewer", user: "a@x"}, "public", "b@x", :write)
      assert Authz.may_access?(%{role: "member", user: "a@x"}, "public", "b@x", :write)
    end

    test "private: only an org member+ (read or write)" do
      refute Authz.may_access?(%{role: "viewer", user: "a@x"}, "private", "b@x", :read)
      assert Authz.may_access?(%{role: "member", user: "a@x"}, "private", "b@x", :read)
      assert Authz.may_access?(%{role: "member", user: "a@x"}, "private", "b@x", :write)
    end

    test "draft: only the owner (or admin+)" do
      assert Authz.may_access?(%{role: "member", user: "owner@x"}, "draft", "owner@x", :write)
      refute Authz.may_access?(%{role: "member", user: "other@x"}, "draft", "owner@x", :write)
      assert Authz.may_access?(%{role: "admin", user: "other@x"}, "draft", "owner@x", :write)
      refute Authz.may_access?(%{role: "member", user: nil}, "draft", "owner@x", :read)
    end
  end
end
