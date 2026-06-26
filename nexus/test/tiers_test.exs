defmodule Nexus.TiersTest do
  @moduledoc "Committed-compute tier parsing, caps, and usage alerts."
  use ExUnit.Case, async: true
  alias Nexus.Tiers

  @config """
  free | Free | 256 1 0 no
  team | Team | 2048 20 49 yes 100000
  scale | Scale | 8192 100 299 yes 1000000
  """

  test "parses each tier line into structured fields" do
    [free, team, scale] = Tiers.parse(@config)
    assert free.id == "free" and free.compute_units == nil and free.domains? == false
    assert team.name == "Team" and team.ram_mb == 2048 and team.price_usd == 49.0
    assert team.domains? and team.compute_units == 100_000
    assert scale.compute_units == 1_000_000
  end

  test "nil/blank config parses to no tiers" do
    assert Tiers.parse(nil) == []
    assert Tiers.parse("   \n  ") == []
  end

  describe "usage status + alerts" do
    setup do
      {:ok, team: Enum.at(Tiers.parse(@config), 1), free: Enum.at(Tiers.parse(@config), 0)}
    end

    test "under 80% is :ok", %{team: team} do
      s = Tiers.usage_status(team, 50_000)
      assert s.state == :ok and s.pct == 50.0
      refute Tiers.alert?(team, 50_000)
    end

    test "80–99% is :warn and raises an alert", %{team: team} do
      assert Tiers.usage_status(team, 85_000).state == :warn
      assert Tiers.alert?(team, 85_000)
      refute Tiers.over_cap?(team, 85_000)
    end

    test "at/over the cap is :over (hard gate)", %{team: team} do
      assert Tiers.usage_status(team, 100_000).state == :over
      assert Tiers.over_cap?(team, 100_000)
      assert Tiers.alert?(team, 120_000)
    end

    test "an uncapped (free) tier never alerts — neutral, no ceiling", %{free: free} do
      assert Tiers.usage_status(free, 999_999).state == :ok
      refute Tiers.alert?(free, 999_999)
    end
  end
end
