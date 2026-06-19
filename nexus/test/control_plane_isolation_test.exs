defmodule Nexus.ControlPlaneIsolationTest do
  use ExUnit.Case, async: false
  alias Nexus.ControlPlane, as: CP

  # The control-plane's whole job is org isolation. These are adversarial: org B actively tries to
  # see/read/mutate/delete org A's records, by id, and must ALWAYS fail.
  @a "org_aaa"
  @b "org_bbb"

  test "list is org-scoped — B never sees A's records" do
    {:ok, _} = CP.put(@a, :nexus, "nx_secret_a", %{name: "A-prod"})
    assert CP.list(@a, :nexus) |> Enum.map(& &1.id) == ["nx_secret_a"]
    assert CP.list(@b, :nexus) == [], "org B saw org A's nexuses — IDOR!"
  end

  test "get by a known id from another org is :not_found (no read across orgs)" do
    {:ok, _} = CP.put(@a, :workspace, "ws_a1", %{name: "A-ws"})
    assert {:ok, %{name: "A-ws"}} = CP.get(@a, :workspace, "ws_a1")
    # B knows the exact id and asks for it — must be denied.
    assert CP.get(@b, :workspace, "ws_a1") == {:error, :not_found}
  end

  test "update from another org cannot touch A's record" do
    {:ok, _} = CP.put(@a, :nexus, "nx_a2", %{name: "A-orig"})
    assert CP.update(@b, :nexus, "nx_a2", %{name: "B-pwned"}) == {:error, :not_found}
    assert {:ok, %{name: "A-orig"}} = CP.get(@a, :nexus, "nx_a2")
  end

  test "delete from another org cannot remove A's record" do
    {:ok, _} = CP.put(@a, :nexus, "nx_a3", %{name: "A-keep"})
    assert CP.delete(@b, :nexus, "nx_a3") == :ok
    # A's record survives a foreign delete.
    assert {:ok, _} = CP.get(@a, :nexus, "nx_a3")
  end

  test "control-plane role is OFF unless WB_CONTROL_PLANE is set" do
    System.delete_env("WB_CONTROL_PLANE")
    refute CP.enabled?()
    System.put_env("WB_CONTROL_PLANE", "1")
    assert CP.enabled?()
  after
    System.delete_env("WB_CONTROL_PLANE")
  end
end
