defmodule Workbooks.SessionTenantGateTest do
  @moduledoc """
  The tenant gate for joining/cancelling a session channel (wb-g1yo.2). Before
  this, ANY socket that knew a session id could join its WS channel and even
  cancel the run. The gate now rejects a definite cross-tenant mismatch while
  grandfathering nil tenants (dev/single-tenant socket, or a legacy run) so the
  desktop + dev flows are unaffected. Tests the pure decision rule.
  """
  use ExUnit.Case, async: true

  alias Workbooks.PhoenixSocket, as: PS

  test "same tenant → allowed" do
    assert PS.tenant_match?("alice", "alice")
  end

  test "different known tenants → DENIED (the leak this closes)" do
    refute PS.tenant_match?("alice", "bob")
  end

  test "legacy run with no tenant → allowed (grandfathered)" do
    assert PS.tenant_match?(nil, "bob")
  end

  test "dev/single-tenant socket with no tenant → allowed (backward-compatible)" do
    assert PS.tenant_match?("alice", nil)
  end

  test "both nil → allowed" do
    assert PS.tenant_match?(nil, nil)
  end
end
