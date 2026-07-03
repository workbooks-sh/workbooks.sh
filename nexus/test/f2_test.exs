defmodule Nexus.F2Test do
  @moduledoc """
  The F2 (JS→BEAM) execution lane wired into nexus: real requests routed through TinyLasers.Gate.Exec.invoke,
  which is supervised by the :tiny_lasers application (booted as a nexus dependency).
  """
  use ExUnit.Case, async: false

  alias Nexus.F2

  defp t, do: "nx_#{System.unique_integer([:positive])}"

  test "the F2 execution model is up, supervised by the :tiny_lasers dependency" do
    assert F2.available?(), "F2 execution model (ModuleCache) not running under the supervisor"
    h = F2.health()
    assert is_float(h.atom_pressure) and h.atom_health in [:ok, :shedding, :critical]
  end

  test "eval routes a real request through Exec.invoke and returns byte-correct output" do
    assert {:ok, ["R[45]"]} =
             F2.eval("var n=0; for(var i=0;i<10;i++){n+=i;} print('R['+n+']');", tenant: t())
  end

  test "Toolkit.Js.invoke(engine: :f2) runs a toolkit function through the F2 lane" do
    js = Nexus.Toolkit.Js.prelude() <> "\nfunction add(a, b){ return a + b; }\n"
    assert {:ok, 7} = Nexus.Toolkit.Js.invoke({:js, js}, "add", [3, 4], engine: :f2, tenant: t())

    # a list result exercises the cons-cell prelude round-trip on the F2 lane too
    js2 = Nexus.Toolkit.Js.prelude() <> "\nfunction pair(a, b){ return $toList([a, b]); }\n"
    assert {:ok, [1, 2]} = Nexus.Toolkit.Js.invoke({:js, js2}, "pair", [1, 2], engine: :f2, tenant: t())
  end

  test "prewarm compiles ahead so the first request is a warm cache hit" do
    tenant = t()
    src = "print('warm');"
    assert %{compiled: 1} = F2.prewarm(tenant, [src])
    before = TinyLasers.Gate.ModuleCache.stats().entries
    assert {:ok, ["warm"]} = F2.eval(src, tenant: tenant)
    assert TinyLasers.Gate.ModuleCache.stats().entries == before, "invoke recompiled instead of hitting the prewarmed module"
  end

  test "the resource guard holds through the nexus F2 lane (a runaway is contained, host survives)" do
    r =
      F2.run("var a=[]; while(true){ a.push('x'.repeat(100000)); }",
        tenant: t(), max_heap_size: 6_500_000, timeout: 2_000)

    assert match?({:resource_killed, _}, r.result) or match?({:timeout, _}, r.result),
           "runaway not contained: #{inspect(r.result)}"

    # host still serves afterward
    assert {:ok, ["ok"]} = F2.eval("print('ok');", tenant: t())
  end
end
