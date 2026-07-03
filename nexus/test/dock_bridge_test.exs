defmodule Nexus.Dock.BridgeTest do
  use ExUnit.Case, async: false
  alias Nexus.Dock.Bridge

  @tenant "bridge-test-tenant"

  test "routes a granted op with typed JSON args → JSON result" do
    # store then load round-trips through the tenant-partitioned kv (proves marshaling both ways)
    assert {:ok, "null"} = Bridge.dispatch("store", ~s(["k1", "hello"]), @tenant, :all)
    assert {:ok, ~s("hello")} = Bridge.dispatch("load", ~s(["k1"]), @tenant, :all)
  end

  test "zero-arg op takes an empty payload" do
    assert {:ok, ts} = Bridge.dispatch("now", "", @tenant, :all)
    assert String.to_integer(ts) > 0
  end

  test "one-arg op, nil-returning" do
    assert {:ok, "null"} = Bridge.dispatch("emit", ~s(["a log line"]), @tenant, :all)
  end

  # THE CONFINEMENT INVARIANT — the whole point of the bridge: an ungranted cap is unreachable.
  test "grant-filtering: an ungranted cap is not routable (confinement preserved)" do
    # `fetch`/`store` require grants; with NO grants only ambient caps (now/emit) are wired.
    assert :error = Bridge.dispatch("fetch", ~s(["http://example.com"]), @tenant, [])
    assert :error = Bridge.dispatch("store", ~s(["k", "v"]), @tenant, [])
    # ambient caps still work with no grants
    assert {:ok, _} = Bridge.dispatch("emit", ~s(["ok"]), @tenant, [])
  end

  test "unknown op → :error" do
    assert :error = Bridge.dispatch("no_such_op", "", @tenant, :all)
  end

  test "tenant partitioning: one tenant can't read another's kv cell" do
    Bridge.dispatch("store", ~s(["shared", "A-secret"]), "tenant-A", :all)
    assert {:ok, ~s("")} = Bridge.dispatch("load", ~s(["shared"]), "tenant-B", :all)
    assert {:ok, ~s("A-secret")} = Bridge.dispatch("load", ~s(["shared"]), "tenant-A", :all)
  end
end
