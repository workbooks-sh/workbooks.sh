defmodule Nexus.WashyPorfforM4Test do
  @moduledoc """
  **M4 tracker — real npm packages through the Porffor lane at build-tooling scale.**

  M3 proved a synthetic real-code corpus (7/7). M4 raises the bar to *unmodified, minified npm
  packages* — the on-ramp to driving the real build tools (svelte compiler, rollup) through Porffor
  byte-identical to the QuickJS goldens. Real packages are CJS/UMD bundles, so each runs with a
  shared `porffor_cjs/cjs_prelude.js` (module/exports/require/process/globalThis surface).

  The session-1 milestone this gates: **every real package COMPILES clean** (the universal Porffor
  f64/i32 string-concat-guard codegen bug + the V8-stack-depth RangeError are fixed, so picocolors/
  dayjs/bignumber/marked all reach codegen). Plus picocolors' simple export path RUNS byte-identical
  to node. The deeper per-package runtime gaps (function-property-bags → bignumber; object-property
  closure method dispatch → picocolors colored path; Date → dayjs; regex breadth → marked) are the
  active M4 work-list (bd) and are intentionally NOT asserted green yet — this test rises as they land.
  """
  use ExUnit.Case, async: false

  @moduletag :porffor
  @conf Path.join(__DIR__, "conformance")
  @prelude Path.join(@conf, "porffor_cjs/cjs_prelude.js")

  @packages ~w(picocolors-1.0.0 dayjs-1.11.10 bignumber-9.1.2 marked-4.3.0)

  setup_all do
    if File.regular?(Nexus.Compilers.Js.Porffor.porf_entry()) and System.find_executable("node"),
      do: :ok,
      else: {:skip, "porffor/node absent"}
  end

  defp prelude, do: File.read!(@prelude)

  test "every real npm package compiles clean through Porffor (no CompileError)" do
    fails =
      for pkg <- @packages do
        src = prelude() <> "\n" <> File.read!(Path.join(@conf, "#{pkg}.js")) <> "\n;\nmodule.exports;\n"
        {pkg, match?({:ok, _}, Nexus.Compilers.Js.Porffor.compile(src))}
      end
      |> Enum.reject(fn {_, ok} -> ok end)
      |> Enum.map(&elem(&1, 0))

    assert fails == [], "real packages must reach codegen (compile clean): failing #{Enum.join(fails, ", ")}"
  end

  test "picocolors runs byte-identical to node — simple export AND colored closure path" do
    driver = ~S"""
    var pc = module.exports;
    console.log("plain=" + pc.red("z"));
    var c = pc.createColors(true);
    console.log("red=" + c.red("x"));
    console.log("bold=" + c.bold("y"));
    """

    src = prelude() <> "\n" <> File.read!(Path.join(@conf, "picocolors-1.0.0.js")) <> "\n;\n" <> driver

    with {:ok, wasm} <- Nexus.Compilers.Js.Porffor.compile(src),
         {:ok, out} <- Nexus.Washy.Sandbox.run_command(wasm, "", transpile: true, timeout_ms: 60_000) do
      got = out |> String.replace("\e", "ESC") |> String.trim()
      # no-TTY ⇒ pc.red is identity ("z"); createColors(true) forces colors — the property closures
      # (formatter(open,close,replace)) must dispatch through the boxed-closure METHOD path (c.red(...)).
      want = "plain=z\nred=ESC[31mxESC[39m\nbold=ESC[1myESC[22m"
      assert got == want, "picocolors mismatch:\n got: #{inspect(got)}\nwant: #{inspect(want)}"
    else
      other -> flunk("picocolors run failed: #{inspect(other)}")
    end
  end
end
