defmodule Nexus.CapacityTest do
  # async: false — these mutate the shared Nexus.Config tier table (persistent_term).
  use ExUnit.Case, async: false
  alias Nexus.{Capacity, Config, Pricing}

  # A FIXTURE tier table — deliberately NOT our product's prices. The runtime is a mechanism; what it
  # must do is operate over whatever tiers an operator configures. (Our real tiers live in our
  # DeployKit config, never in lib/ — THE LINE.)
  @fixture [
    %{id: "free", name: "Free", ram_mb: 512, storage_gb: 5, price: 0, domains?: false},
    %{id: "pro", name: "Pro", ram_mb: 2_048, storage_gb: 50, price: 19, domains?: true},
    %{id: "max", name: "Max", ram_mb: 8_192, storage_gb: 500, price: 99, domains?: true}
  ]

  setup do
    Config.put(:tiers, @fixture)
    on_exit(fn -> Config.boot() end)
    :ok
  end

  test "pricing logic operates over the CONFIGURED table: order, next, domain gate" do
    assert Pricing.default_tier().id == "free"
    assert Pricing.tier("free").price == 0
    assert Pricing.tier("nonsense").id == "free"
    assert Pricing.next_tier("free").id == "pro"
    assert Pricing.next_tier("max") == nil
    refute Pricing.domains?("free")
    assert Pricing.domains?("pro")
  end

  test "neutral default when an operator configures no tiers" do
    Config.reload("")
    assert [t] = Pricing.tiers()
    assert t.id == "default"
    assert t.price == 0
    assert t.domains? == true
  end

  test "tiers parse from a deploy config block" do
    Config.reload(~S"""
    deploy do
      tiers="
        small | Small | 256 2 0 no
        big   | Big   | 4096 200 49 yes
      "
    end
    """)

    assert length(Pricing.tiers()) == 2
    assert Pricing.tier("small").ram_mb == 256
    assert Pricing.tier("big").domains? == true
    assert Pricing.next_tier("small").id == "big"
  end

  test "status thresholds: ok < 80% ≤ near < 100% ≤ over" do
    assert Pricing.status(10, 100) == :ok
    assert Pricing.status(80, 100) == :near
    assert Pricing.status(100, 100) == :over
    assert Pricing.status(5, 0) == :ok
  end

  test "report(nil): default-tier ceiling, zero usage, no shed list" do
    r = Capacity.report(nil)
    assert r.tier.id == "free"
    assert r.ram.used == 0
    assert r.ram.limit == 512
    assert r.topRam == []
  end

  test "report(running nexus): RAM dial within ceiling, consumers when hot" do
    nx = %{id: "nx-hot", plan: "pro", state: "running"}
    r = Capacity.report(nx)

    assert r.tier.id == "pro"
    assert r.ram.used <= r.ram.limit
    assert r.ram.pct >= 0 and r.ram.pct <= 100
    assert r.ram.status in ["ok", "near", "over"]

    if r.ram.status != "ok" do
      assert length(r.topRam) > 0
      assert Enum.all?(r.topRam, &(&1.mb > 0))
    end
  end

  test "stopped nexus uses no RAM" do
    r = Capacity.report(%{id: "nx-cold", plan: "pro", state: "stopped"})
    assert r.ram.used == 0
    assert r.activeHrs == 0
  end
end
