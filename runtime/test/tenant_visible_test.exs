defmodule Workbooks.TenantVisibleTest do
  @moduledoc """
  The ONE multi-tenant visibility rule (wb-g1yo) that every scoped surface now
  delegates to. Pinning it here means the security semantics are defined + tested
  in exactly one place.
  """
  use ExUnit.Case, async: true

  alias Workbooks.Tenant

  test "same tenant → visible" do
    assert Tenant.visible?("alice", "alice")
  end

  test "different known tenants → DENIED (the cross-tenant case all scoping rejects)" do
    refute Tenant.visible?("alice", "bob")
  end

  test "nil owner (legacy/local resource) → visible to any caller" do
    assert Tenant.visible?(nil, "bob")
  end

  test "nil caller (admin/internal/dev) → sees any owner" do
    assert Tenant.visible?("alice", nil)
  end

  test "both nil → visible" do
    assert Tenant.visible?(nil, nil)
  end
end
