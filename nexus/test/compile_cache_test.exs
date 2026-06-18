defmodule Nexus.CompileCacheTest do
  use ExUnit.Case, async: false

  # Exercise the content-addressed cache mechanics WITHOUT the real ~20s compiler: a fake `build`
  # writes a dummy component and counts invocations. Same (kind+name+body) → compiled once, served many.
  defp mknode(body), do: %{type: :code, kind: "c", name: "cachetest_#{System.unique_integer([:positive])}", body: body}

  defp fake_build(counter) do
    fn ->
      Agent.update(counter, &(&1 + 1))
      p = Path.join(System.tmp_dir!(), "fake_#{System.unique_integer([:positive])}.wasm")
      File.write!(p, "DUMMYCOMPONENT")
      {:ok, p}
    end
  end

  test "identical source compiles once, then hits the store" do
    {:ok, c} = Agent.start_link(fn -> 0 end)
    n = mknode("int add(int a,int b){return a+b;}")
    b = fake_build(c)

    {:ok, p1} = Nexus.Compile.cached(n, b)
    {:ok, p2} = Nexus.Compile.cached(n, b)

    assert Agent.get(c, & &1) == 1, "build ran more than once — cache missed on identical source"
    assert p1 == p2 and String.contains?(p1, "build/components")
    assert File.read!(p1) == "DUMMYCOMPONENT"
    File.rm(p1)
  end

  test "a changed body is a different key (cold miss)" do
    {:ok, c} = Agent.start_link(fn -> 0 end)
    b = fake_build(c)
    {:ok, p1} = Nexus.Compile.cached(mknode("int a(){return 1;}"), b)
    {:ok, p2} = Nexus.Compile.cached(mknode("int a(){return 2;}"), b)
    assert Agent.get(c, & &1) == 2 and p1 != p2
    File.rm(p1); File.rm(p2)
  end

  test "compile-cache=off (config) bypasses the store" do
    Nexus.Config.put(:compile_cache, false)
    {:ok, c} = Agent.start_link(fn -> 0 end)
    n = mknode("int z(){return 0;}")
    b = fake_build(c)
    Nexus.Compile.cached(n, b)
    Nexus.Compile.cached(n, b)
    assert Agent.get(c, & &1) == 2, "cache should be disabled"
  after
    Nexus.Config.put(:compile_cache, true)
  end
end
