defmodule Nexus.Washy.DensityTest do
  use ExUnit.Case, async: true

  alias Nexus.Washy.Density

  describe "report/0" do
    test "returns every watched metric, all numeric and live" do
      r = Density.report()

      for key <- [
            :atom_count,
            :atom_limit,
            :atom_frac,
            :loaded_modules,
            :process_count,
            :eheap_carrier_frac,
            :literal_carrier_bytes,
            :binary_bytes,
            :total_ram_bytes,
            :binary_frac
          ] do
        assert Map.has_key?(r, key), "report missing #{key}"
        assert is_number(r[key]), "#{key} should be numeric, got #{inspect(r[key])}"
      end

      assert r.atom_count > 0
      assert r.atom_limit >= r.atom_count
      assert r.atom_frac >= 0.0 and r.atom_frac <= 1.0
      assert r.loaded_modules > 0
      assert r.eheap_carrier_frac >= 1.0
      assert Map.has_key?(r, :runtime)
    end
  end

  describe "assess/0 on the live node" do
    test "every wall is :ok on a healthy test node" do
      assessments = Density.assess()

      assert length(assessments) == 5

      for a <- assessments do
        assert a.status in [:ok, :warn, :danger]
        assert is_binary(a.remediation) and a.remediation != ""
      end

      # A test node nowhere near the walls should classify everything :ok.
      assert Density.worst_status(assessments) == :ok
    end

    test "covers the five named walls" do
      metrics = Density.assess() |> Enum.map(& &1.metric) |> MapSet.new()
      assert MapSet.equal?(metrics, MapSet.new([:atoms, :modules, :frag, :literal, :binary]))
    end
  end

  describe "classify/5 — synthetic threshold checks" do
    test "atom fraction: 0.04 ok, 0.72 warn, 0.90 danger" do
      assert Density.classify(:atoms, 0.04, 0.70, 0.85, "fix").status == :ok
      assert Density.classify(:atoms, 0.72, 0.70, 0.85, "fix").status == :warn
      assert Density.classify(:atoms, 0.90, 0.70, 0.85, "fix").status == :danger
    end

    test "loaded modules: 300 ok, 120_000 danger" do
      assert Density.classify(:modules, 300, 50_000, 100_000, "fix").status == :ok
      assert Density.classify(:modules, 120_000, 50_000, 100_000, "fix").status == :danger
    end

    test "carrier fragmentation: 1.0 ok, 1.3 danger" do
      assert Density.classify(:frag, 1.0, 1.1, 1.2, "fix").status == :ok
      assert Density.classify(:frag, 1.3, 1.1, 1.2, "fix").status == :danger
    end

    test "boundary is inclusive — exactly at danger classifies :danger" do
      assert Density.classify(:x, 0.85, 0.70, 0.85, "fix").status == :danger
      assert Density.classify(:x, 0.70, 0.70, 0.85, "fix").status == :warn
    end

    test "carries metric, value and remediation through unchanged" do
      out = Density.classify(:binary, 0.6, 0.35, 0.50, "force GC")
      assert out == %{metric: :binary, value: 0.6, status: :danger, remediation: "force GC"}
    end
  end

  describe "worst_status/1" do
    test "danger dominates warn dominates ok" do
      mk = fn s -> %{metric: :m, value: 0, status: s, remediation: "r"} end
      assert Density.worst_status([mk.(:ok), mk.(:ok)]) == :ok
      assert Density.worst_status([mk.(:ok), mk.(:warn)]) == :warn
      assert Density.worst_status([mk.(:warn), mk.(:danger)]) == :danger
    end
  end

  describe "summary/0" do
    test "one-liner with the headline metrics and a status word" do
      s = Density.summary()
      assert is_binary(s)
      assert s =~ "atoms"
      assert s =~ "modules"
      assert s =~ "binary"
      assert s =~ ~r/OK|WARN|DANGER/
    end
  end
end
