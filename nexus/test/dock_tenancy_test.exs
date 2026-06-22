defmodule Nexus.DockTenancyTest do
  use ExUnit.Case, async: false

  # wb-ynlx — the Dock seam must (1) partition every stateful cap by a host-supplied tenant so one
  # guest can never read/poison another tenant's data, and (2) wire ONLY the caps a unit granted.

  defp impl(map, name) do
    {_sig, f} = Map.fetch!(map, name)
    f
  end

  describe "tenant-partitioned store/load" do
    test "tenant A cannot read tenant B's stored key" do
      a = Nexus.Dock.host_fns("tenant-a")
      b = Nexus.Dock.host_fns("tenant-b")

      impl(a, "store").("secret", "from-a")
      # same key name, different tenant → distinct cell
      assert impl(a, "load").("secret") == "from-a"
      assert impl(b, "load").("secret") == ""

      impl(b, "store").("secret", "from-b")
      assert impl(a, "load").("secret") == "from-a"
      assert impl(b, "load").("secret") == "from-b"
    end
  end

  describe "grant-filtered import map" do
    test "no grants → only ambient caps wired (now/emit), no data/net/llm" do
      m = Nexus.Dock.impls("t", [])
      assert Map.has_key?(m, "now")
      assert Map.has_key?(m, "emit")
      refute Map.has_key?(m, "store")
      refute Map.has_key?(m, "load")
      refute Map.has_key?(m, "cache_get")
      refute Map.has_key?(m, "fetch")
      refute Map.has_key?(m, "complete")
    end

    test "kv grant unlocks store/load/cache but not net/llm" do
      m = Nexus.Dock.impls("t", ["kv"])
      assert Map.has_key?(m, "store")
      assert Map.has_key?(m, "cache_put")
      refute Map.has_key?(m, "fetch")
      refute Map.has_key?(m, "complete")
    end

    test "net grant unlocks fetch only; llm unlocks complete only" do
      net = Nexus.Dock.impls("t", ["net"])
      assert Map.has_key?(net, "fetch")
      refute Map.has_key?(net, "store")
      refute Map.has_key?(net, "complete")

      llm = Nexus.Dock.impls("t", ["llm"])
      assert Map.has_key?(llm, "complete")
      refute Map.has_key?(llm, "fetch")
    end

    test ":all wires the full surface (trusted/in-tree default)" do
      m = Nexus.Dock.impls("t", :all)
      for n <- ~w(now emit store load cache_get cache_put cache_delete fetch complete) do
        assert Map.has_key?(m, n), "expected #{n} in full surface"
      end
    end

    test "grant_for maps imports to unlocking grant words; ambient → []" do
      assert Nexus.Dock.grant_for("fetch") == ["net", "browse"]
      assert Nexus.Dock.grant_for("complete") == ["llm"]
      assert Nexus.Dock.grant_for("store") == ["kv"]
      assert Nexus.Dock.grant_for("now") == []
    end
  end
end
