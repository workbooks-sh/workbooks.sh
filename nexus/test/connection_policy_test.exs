defmodule Nexus.ConnectionPolicyTest do
  use ExUnit.Case, async: false
  alias Nexus.ConnectionPolicy, as: Policy
  alias Nexus.ControlPlane, as: CP

  @org "org_connpol"

  setup do
    {:ok, _} = CP.put(@org, :integration, "intg_test", %{provider: "github", label: "acme"})
    on_exit(fn -> CP.delete(@org, :integration, "intg_test") end)
    :ok
  end

  test "an unrestricted connection allows every grant" do
    assert Policy.allowed?(@org, "intg_test", "repo")
    assert Policy.allowed?(@org, "intg_test", "anything")
  end

  test "restricting to a subset blocks the rest" do
    {:ok, ["repo"]} = Policy.set(@org, "intg_test", ["repo"])
    assert Policy.allowed?(@org, "intg_test", "repo")
    refute Policy.allowed?(@org, "intg_test", "workflow")
  end

  test "an empty allow-list is a fully paused connection" do
    {:ok, []} = Policy.set(@org, "intg_test", [])
    refute Policy.allowed?(@org, "intg_test", "repo")
  end

  test "set intersects against the real grant surface — a forged key cannot widen access" do
    {:ok, allowed} = Policy.set(@org, "intg_test", ["repo", "forged:admin"], valid_keys: ["repo", "workflow"])
    assert allowed == ["repo"]
    refute Policy.allowed?(@org, "intg_test", "forged:admin")
  end

  test "clear restores the full surface" do
    {:ok, _} = Policy.set(@org, "intg_test", [])
    :ok = Policy.clear(@org, "intg_test")
    assert Policy.allowed?(@org, "intg_test", "repo")
  end

  test "a missing connection denies everything" do
    refute Policy.allowed?(@org, "intg_nope", "repo")
  end

  test "argv_grant maps a CLI command group to its grant key, skipping flags" do
    grants = %{"gmail" => "gmail", "admin" => "admin"}
    assert Policy.argv_grant(grants, ["gws", "gmail", "+send"]) == "gmail"
    assert Policy.argv_grant(grants, ["gws", "--json", "admin", "users", "list"]) == "admin"
    assert Policy.argv_grant(grants, ["gws", "calendar", "events"]) == nil
    assert Policy.argv_grant(grants, ["gws"]) == nil
  end
end
