defmodule Workbooks.ControlPlaneTenantTest do
  @moduledoc """
  Tenant-scoping of GET /instances (wb-g1yo.4): ControlPlane.list/1 must return
  only the caller tenant's instances (+ legacy rows), not every instance on a
  shared nexus. Runs against the app-started ControlPlane.
  """
  use ExUnit.Case, async: false

  alias Workbooks.ControlPlane

  test "list/1 scopes instances to the caller tenant; nil = all (admin)" do
    ControlPlane.register("cp-alice-#{System.unique_integer([:positive])}", "cp-alice", "/vfs/a")
    ControlPlane.register("cp-bob-#{System.unique_integer([:positive])}", "cp-bob", "/vfs/b")

    tenants_for = fn t ->
      ControlPlane.list(t) |> Enum.map(fn [_id, ten, _state] -> ten end) |> Enum.uniq()
    end

    alice = tenants_for.("cp-alice")
    assert "cp-alice" in alice
    refute "cp-bob" in alice

    bob = tenants_for.("cp-bob")
    assert "cp-bob" in bob
    refute "cp-alice" in bob

    # nil caller (admin/internal) sees both
    all = tenants_for.(nil)
    assert "cp-alice" in all and "cp-bob" in all
  end
end
