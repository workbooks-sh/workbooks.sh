defmodule Workbooks.IsolationTest do
  @moduledoc """
  wb-rhs.10 — the isolation TIER ladder, the depth knob of the (width, tier)
  surface. The tier must be selectable, observable, and defaulted from #+TRUST,
  with honest statuses (nothing claims to work before it does).
  """
  use ExUnit.Case, async: true

  alias Workbooks.Isolation

  test "the four tiers exist with honest statuses" do
    assert Isolation.status(:instance) == :live
    assert Isolation.status(:os_process) == :available
    assert Isolation.status(:node) == :planned
    assert Isolation.status(:container) == :planned
    assert Isolation.status(:bogus) == :unknown
  end

  test "only :instance is live today" do
    assert Isolation.live?(:instance)
    refute Isolation.live?(:os_process)
    refute Isolation.live?(:node)
    assert Isolation.known?(:container)
    refute Isolation.known?(:bogus)
  end

  test "default tier derives from #+TRUST posture" do
    assert Isolation.default_for_trust("first-party") == :instance
    assert Isolation.default_for_trust(nil) == :instance
    assert Isolation.default_for_trust("third-party") == :os_process
  end

  test "resolve gives a runnable tier or a status-aware reason" do
    assert {:ok, :instance} = Isolation.resolve(:instance)
    assert {:error, {:tier_not_wired, :os_process, _}} = Isolation.resolve(:os_process)
    assert {:error, {:tier_planned, :node, _}} = Isolation.resolve(:node)
    assert {:error, {:tier_planned, :container, _}} = Isolation.resolve(:container)
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

  test "wb isolation surfaces the ladder to an agent via the CLI" do
    out = Workbooks.CLI.call(["isolation"], nil)
    assert out =~ "Isolation tiers"
    assert out =~ "instance"
  end
end
