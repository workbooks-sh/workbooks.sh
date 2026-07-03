defmodule TinyLasers.Wasm.HostDockTest do
  @moduledoc "wb-vhq1u Step 3: the nexus dock concern for TL's typed host-call ABI (contract §4)."
  use ExUnit.Case, async: false
  alias TinyLasers.Wasm.HostDock

  setup do
    Process.put(:dock_tenant, "hostdock-test")
    Process.put(:dock_caps, :all)
    :ok
  end

  test "routes dock_<op> → Dock impl (decoded args in, raw term out — runtime does §2 marshaling)" do
    assert nil == HostDock.call("dock_store", ["k1", "hello"])
    assert "hello" == HostDock.call("dock_load", ["k1"])
  end

  test "zero-arg op takes an empty args list" do
    assert HostDock.call("dock_now", []) > 0
  end

  # THE CONFINEMENT INVARIANT — the whole reason the bridge exists.
  test "ungranted cap raises → the guest traps, cannot reach it" do
    Process.put(:dock_caps, [])
    assert_raise ArgumentError, fn -> HostDock.call("dock_fetch", ["http://example.com"]) end
    assert_raise ArgumentError, fn -> HostDock.call("dock_store", ["k", "v"]) end
    # ambient caps (now/emit) still work with no grants
    assert nil == HostDock.call("dock_emit", ["ok"])
  end

  test "unknown op raises" do
    assert_raise ArgumentError, fn -> HostDock.call("dock_no_such_op", []) end
  end

  test "tenant partitioning: one tenant can't read another's kv cell" do
    Process.put(:dock_tenant, "tenant-A")
    HostDock.call("dock_store", ["shared", "A-secret"])
    Process.put(:dock_tenant, "tenant-B")
    assert "" == HostDock.call("dock_load", ["shared"])
    Process.put(:dock_tenant, "tenant-A")
    assert "A-secret" == HostDock.call("dock_load", ["shared"])
  end
end
