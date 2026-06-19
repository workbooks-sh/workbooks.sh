defmodule Nexus.CapacityTest do
  use ExUnit.Case, async: true
  alias Nexus.{Capacity, Pricing}

  test "pricing tiers: ordering, next, domain gate" do
    assert Pricing.tier("starter").price == 0
    assert Pricing.tier("nonsense").id == "starter"
    assert Pricing.next_tier("starter").id == "team"
    assert Pricing.next_tier("scale") == nil
    refute Pricing.domains?("starter")
    assert Pricing.domains?("team")
  end

  test "status thresholds: ok < 80% ≤ near < 100% ≤ over" do
    assert Pricing.status(10, 100) == :ok
    assert Pricing.status(80, 100) == :near
    assert Pricing.status(100, 100) == :over
    assert Pricing.status(5, 0) == :ok
  end

  test "report(nil): starter ceiling, zero usage, no shed list" do
    r = Capacity.report(nil)
    assert r.tier.id == "starter"
    assert r.ram.used == 0
    assert r.ram.limit == 1024
    assert r.topRam == []
  end

  test "report(running nexus): RAM dial within ceiling, consumers when hot" do
    nx = %{id: "nx-hot", plan: "team", state: "running"}
    r = Capacity.report(nx)

    assert r.tier.id == "team"
    assert r.ram.used <= r.ram.limit
    assert r.ram.pct >= 0 and r.ram.pct <= 100
    assert r.ram.status in ["ok", "near", "over"]

    # When a dial is near/over, the shed list is populated and sums sensibly.
    if r.ram.status != "ok" do
      assert length(r.topRam) > 0
      assert Enum.all?(r.topRam, &(&1.mb > 0))
    end
  end

  test "stopped nexus uses no RAM" do
    r = Capacity.report(%{id: "nx-cold", plan: "team", state: "stopped"})
    assert r.ram.used == 0
    assert r.activeHrs == 0
  end
end
