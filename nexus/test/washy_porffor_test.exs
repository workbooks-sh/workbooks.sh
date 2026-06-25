defmodule Nexus.WashyPorfforTest do
  @moduledoc """
  **The Porffor JS→wasm fast lane: compile JS on the host, run the wasm on Washy, near-native.**

  Porffor compiles the JS *program* directly to a tiny wasm module (no inner JS interpreter); Washy runs it
  on the transpiler lane. Proven ~2500× faster than quickjs-on-Washy on the AOT-friendly subset. This test
  exercises the round-trip (`Porffor.eval/1`: source → wasm → run → stdout) across the subset that works
  today — arithmetic, loops, array/string methods, JSON. Skipped if Porffor isn't vendored
  (`compilers/js/porffor/`, host-Node toolchain — shipped via the compilers package, not git).
  """
  use ExUnit.Case, async: false

  alias Nexus.Compilers.Js.Porffor

  @moduletag :porffor

  setup_all do
    if File.regular?(Porffor.porf_entry()) and System.find_executable("node") do
      :ok
    else
      {:skip, "porffor not vendored / node absent"}
    end
  end

  defp ok(src, want) do
    assert {:ok, out} = Porffor.eval(src), "eval failed for: #{src}"
    got = out |> String.replace(~r/\e\[[0-9;]*m/, "") |> String.trim()
    assert got == want, "#{src}\n  got=#{inspect(got)} want=#{inspect(want)}"
  end

  test "arithmetic + loops" do
    ok("let s=0; for(let i=0;i<1000;i++) s+=i*2; console.log(s);", "999000")
    ok("console.log(2**10 + 1_000);", "2024")
    ok("let r=0; outer: for(let i=0;i<3;i++){switch(i){case 1: r+=10; break; default: r+=1;}} console.log(r);", "12")
  end

  test "array + string methods (multi-value / type-tagged returns)" do
    ok("console.log([1,2,3,4].filter(n=>n%2).map(n=>n*n).reduce((a,b)=>a+b,0));", "10")
    ok("console.log('Hello World'.toLowerCase().split(' ').join('-').slice(0,5));", "hello")
  end

  test "objects + JSON + destructuring" do
    ok("console.log(JSON.stringify({a:[1,2],b:'x'}));", ~s({"a":[1,2],"b":"x"}))
    ok("console.log(JSON.parse('{\"a\":5}').a);", "5")
    ok("const {a,b=5}={a:1}; const [x,...y]=[1,2,3]; console.log(a+b+x+y.length);", "9")
  end

  test "classes + inheritance + super" do
    ok("class A{m(){return 1;}} class B extends A{m(){return super.m()+1;}} console.log(new B().m());", "2")
  end

  test "conformance census: pass rate does not regress + currently-clean categories stay clean" do
    results = Nexus.Compilers.Js.Porffor.Census.run()

    pass = Enum.count(results, fn {_, _, s, _, _} -> s == :pass end)
    run = Enum.count(results, fn {_, _, s, _, _} -> s != :oracle_skip end)

    # Regression FLOOR (Phase 1 baseline = 44/57). Raise this as the fork fixes features.
    assert pass >= 53, "porffor conformance regressed: #{pass}/#{run} (run `Census.report()` for detail)"

    # Categories at 100% today must stay clean (catches a regression that breaks a working feature).
    clean = ~w(control array json number arith template object class collection)a
    broke =
      for {cat, name, status, got, want} <- results,
          cat in clean,
          status in [:miscompile, :crash],
          do: "#{cat}/#{name}: got=#{inspect(got)} want=#{inspect(want)}"

    assert broke == [], "regression in a clean category:\n  " <> Enum.join(broke, "\n  ")
  end

  test "a hard compile failure (syntax error) classifies as :unsupported" do
    # NB: most Porffor misses are SILENT (it compiles, but miscompiles a buggy feature at runtime — caught
    # by the conformance harness, not here). Only genuine compile-time failures surface as :unsupported.
    assert {:error, :unsupported} = Porffor.compile("function ( { [[[ invalid")
  end
end
