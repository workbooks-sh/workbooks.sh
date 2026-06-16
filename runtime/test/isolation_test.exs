defmodule Workbooks.IsolationTest do
  @moduledoc """
  wb-rhs.10 — the isolation TIER ladder, the depth knob of the (width, tier)
  surface. The tier must be selectable, observable, and defaulted from #+TRUST,
  with honest statuses (nothing claims to work before it does).
  """
  use ExUnit.Case, async: true

  alias Workbooks.Isolation

  test "tier statuses are honest: all four tiers live" do
    # Corrected: commands ALWAYS run as subprocess wasmtime (run_wasmtime), so
    # :os_process is live, not 'available'. :instance is the in-VM kernel/component path.
    assert Isolation.status(:instance) == :live
    assert Isolation.status(:os_process) == :live
    assert Isolation.status(:node) == :live
    assert Isolation.status(:container) == :live
    assert Isolation.status(:bogus) == :unknown
  end

  test "all four isolation tiers are live" do
    assert Isolation.live?(:instance)
    assert Isolation.live?(:os_process)
    assert Isolation.live?(:node)
    assert Isolation.live?(:container)
    refute Isolation.known?(:bogus)
  end

  test "tier_for_shape maps #+EXEC shape → its real tier" do
    assert Isolation.tier_for_shape("command") == :os_process
    assert Isolation.tier_for_shape("posix") == :os_process
    assert Isolation.tier_for_shape("kernel") == :instance
    assert Isolation.tier_for_shape("component") == :instance
    assert Isolation.tier_for_shape("task") == nil
    assert Isolation.tier_for_shape(nil) == nil
  end

  test "default tier derives from #+TRUST posture" do
    assert Isolation.default_for_trust("first-party") == :instance
    assert Isolation.default_for_trust(nil) == :instance
    assert Isolation.default_for_trust("third-party") == :node
  end

  test "resolve gives a runnable tier or a status-aware reason" do
    assert {:ok, :instance} = Isolation.resolve(:instance)
    assert {:ok, :os_process} = Isolation.resolve(:os_process)
    assert {:ok, :node} = Isolation.resolve(:node)
    assert {:ok, :container} = Isolation.resolve(:container)
    assert {:error, {:unknown_tier, :bogus, _}} = Isolation.resolve(:bogus)
  end

  test "describe/0 renders the ladder so the tier is observable" do
    out = Isolation.describe()
    assert out =~ "instance"
    assert out =~ "os_process"
    assert out =~ "node"
    assert out =~ "container"
    assert out =~ "[live]"
    assert out =~ "#+TRUST"
  end

  test "work isolation surfaces the ladder to an agent via the CLI" do
    out = Workbooks.CLI.call(["isolation"], nil)
    assert out =~ "Isolation tiers"
    assert out =~ "instance"
  end
end
