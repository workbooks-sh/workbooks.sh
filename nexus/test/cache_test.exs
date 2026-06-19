defmodule Nexus.CacheTest do
  # async: false — the hot tier is a single named GenServer + ETS table shared process-wide.
  use ExUnit.Case, async: false

  alias Nexus.Cache
  alias Nexus.Cache.Tiered

  setup do
    # Default config (cache-hot-max-mb=64, cache-default-ttl=3600), but point the cold tier at a fresh
    # tmp dir → Nexus.Cache.Cold.Local IS the cold double: no network, no R2 creds, no mock, and it
    # exercises the real tenant-scoped object path / isolation that ships.
    Nexus.Config.reload(nil)
    cold_dir = Path.join(System.tmp_dir!(), "cachetest_#{System.unique_integer([:positive])}")
    Nexus.Config.put(:cache_cold, cold_dir)
    Application.delete_env(:nexus, :cache_cold)

    # Reuse the supervised hot tier but reset it to a clean slate per test (clear ETS, restore the
    # configured byte budget). Avoids racing the supervisor by stopping/restarting the named process.
    unless Process.whereis(Tiered), do: {:ok, _} = Tiered.start_link([])

    :sys.replace_state(Tiered, fn s ->
      :ets.delete_all_objects(s.table)
      %{s | bytes: 0, max_bytes: 64 * 1024 * 1024}
    end)

    on_exit(fn -> File.rm_rf(cold_dir) end)
    :ok
  end

  test "put then get is a hot hit" do
    assert :ok = Cache.put("t1", "ns", "k", "v1")
    assert {:ok, "v1"} = Cache.get("t1", "ns", "k")
  end

  test "missing key returns :miss" do
    assert :miss = Cache.get("t1", "ns", "absent")
  end

  test "ttl expiry: a hot entry whose ttl has passed is a miss" do
    assert :ok = Cache.put("t1", "ns", "k", "v", ttl: 1)
    assert {:ok, "v"} = Cache.get("t1", "ns", "k")

    # Rewrite the hot row's expires_at into the past, then read — lazy expiry must drop it.
    :sys.replace_state(Tiered, fn s ->
      :ets.update_element(:nexus_cache_hot, {"t1", "ns", "k"}, {3, System.os_time(:second) - 1})
      s
    end)

    assert :miss = Cache.get("t1", "ns", "k")
  end

  test "expired cold entry is not promoted (treated as miss)" do
    # Seed cold directly with an already-expired entry; a hot miss must NOT promote it.
    Nexus.Cache.Cold.put("t1", "ns", "old", {"stale", System.os_time(:second) - 10})
    assert :miss = Cache.get("t1", "ns", "old")

    # A live cold entry, by contrast, promotes back into hot.
    Nexus.Cache.Cold.put("t1", "ns", "fresh", {"good", System.os_time(:second) + 600})
    assert {:ok, "good"} = Cache.get("t1", "ns", "fresh")
    # now served from hot (stats shows a row present)
    assert Tiered.stats().entries >= 1
  end

  test "delete removes from both tiers" do
    Cache.put("t1", "ns", "k", "v")
    assert {:ok, "v"} = Cache.get("t1", "ns", "k")
    assert :ok = Cache.delete("t1", "ns", "k")
    assert :miss = Cache.get("t1", "ns", "k")
  end

  test "fetch read-through: runs fun on miss, caches, then hits" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    f = fn ->
      Agent.update(agent, &(&1 + 1))
      "computed"
    end

    assert "computed" = Cache.fetch("t1", "ns", "rk", f)
    assert "computed" = Cache.fetch("t1", "ns", "rk", f)
    # fun ran exactly once — second call was a cache hit.
    assert Agent.get(agent, & &1) == 1
  end

  test "LRU eviction at the byte threshold demotes to cold and stays retrievable (promote-on-read)" do
    # Shrink the hot budget to 0 → every put overflows and immediately demotes to cold.
    :sys.replace_state(Tiered, fn s -> %{s | max_bytes: 0} end)
    big = String.duplicate("x", 1024)
    assert :ok = Cache.put("t1", "ns", "a", big)

    # With a 0-byte hot budget the entry can't live hot; it must have demoted to cold and still read
    # back (promoted on the next get).
    assert {:ok, ^big} = Cache.get("t1", "ns", "a")
  end

  test "LRU victim is the least-recently-used entry (touched entry survives)" do
    # Set a hot budget that holds two ~1KB entries but not three, by writing it straight into state.
    :sys.replace_state(Tiered, fn s -> %{s | max_bytes: 2300} end)
    v = String.duplicate("x", 1024)

    Cache.put("t1", "ns", "a", v)
    Cache.put("t1", "ns", "b", v)
    # touch "a" so "b" becomes least-recently-used.
    assert {:ok, ^v} = Cache.get("t1", "ns", "a")
    # third put overflows → evict the LRU victim ("b"), demoting it to cold.
    Cache.put("t1", "ns", "c", v)

    s = Tiered.stats()
    assert s.bytes <= s.max_bytes
    # "a" and "c" stay hot; "b" was demoted but is still retrievable (promote-on-read).
    assert {:ok, ^v} = Cache.get("t1", "ns", "b")
  end

  test "tenant isolation: tenant A cannot read tenant B's key (hot or cold)" do
    Cache.put("A", "ns", "secret", "A-value")
    Cache.put("B", "ns", "secret", "B-value")

    assert {:ok, "A-value"} = Cache.get("A", "ns", "secret")
    assert {:ok, "B-value"} = Cache.get("B", "ns", "secret")

    # B never sees A's value under the same namespace+key.
    Cache.delete("B", "ns", "secret")
    assert :miss = Cache.get("B", "ns", "secret")
    # A is untouched.
    assert {:ok, "A-value"} = Cache.get("A", "ns", "secret")

    # And a key only A wrote is invisible to B entirely.
    Cache.put("A", "ns", "a-only", "x")
    assert :miss = Cache.get("B", "ns", "a-only")
  end

  test "cold object path embeds the tenant (structural isolation)" do
    pa = Nexus.Cache.Cold.object_path("A", "ns", "k")
    pb = Nexus.Cache.Cold.object_path("B", "ns", "k")
    assert pa != pb
    assert String.contains?(pa, "/A/")
    assert String.contains?(pb, "/B/")
  end

  test "wit/0 projects a valid-looking cache interface" do
    wit = Cache.wit()
    assert wit =~ "interface cache"
    assert wit =~ "get: func(key: string) -> option<list<u8>>"
    assert wit =~ "put: func(key: string, val: list<u8>, ttl: u32)"
    assert wit =~ "delete: func(key: string)"
  end
end
