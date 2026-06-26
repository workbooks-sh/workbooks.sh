defmodule Nexus.PorfforRegexReplaceTest do
  @moduledoc """
  Guards the regex/replace correctness fixes that unblocked marked bold/em rendering on the Porffor→Washy
  lane (and the durable debug tool that found them). Each ran byte-identical to node before being asserted.

  - RegExp flag accessors (`ignoreCase`/`multiline`/`dotAll`/`sticky`): the `& mask` result (2,4,8,…) only
    kept bit 0, so only `global` worked. Fixed with `!= 0` normalization (regexp.ts).
  - `String#replace(re, "$1")` $-templates: the old `split().join()` shim emitted the literal "$1" and
    dropped captures, corrupting marked's grammar regex. Fixed with a template-aware exec loop (spread_desugar).
  - `i32.trunc_sat` of NaN/±Inf: the interpreter fed the `{:nonfinite,…}` tuple into a bitwise op → ArithmeticError
    (marked's emStrong regex produces a NaN). Fixed to saturate per spec (washy.ex).
  """
  use ExUnit.Case, async: false

  alias Nexus.Compilers.Js.Porffor
  alias Nexus.Washy.Sandbox

  @prelude Path.join(__DIR__, "conformance/porffor_cjs/cjs_prelude.js")

  setup_all do
    if File.regular?(Porffor.porf_entry()) and System.find_executable("node"),
      do: :ok,
      else: {:skip, "porffor/node absent"}
  end

  defp run(js) do
    {:ok, report} = Nexus.Porffor.Debug.diagnose(File.read!(@prelude) <> "\n" <> js, fuel: 1_000_000_000)
    assert report.completed, "run did not complete: #{inspect(report.trap || report.error)}"
    report.output
  end

  test "RegExp flag accessors are byte-identical to node" do
    out =
      run(~S"""
      var a = new RegExp("x","i");
      var c = new RegExp("z","gi");
      console.log(a.ignoreCase + "," + a.global + "," + c.flags + "," + c.global + "," + c.ignoreCase);
      """)

    assert out == "true,false,gi,true,true\n"
  end

  test "String#replace with $1 capture template expands (not literal)" do
    out =
      run(~S"""
      console.log("x`^y".replace(/(^|[^\[])\^/g, "$1"));
      console.log("a^b".replace(/(a)\^/g, "[$1]"));
      """)

    assert out == "x`y\n[a]b\n"
  end

  test "marked bold/em renders <strong> (the unblocked path)" do
    marked = File.read!(Path.join(__DIR__, "conformance/marked-4.3.0.js"))

    out =
      run(marked <> "\n;\nvar parse = module.exports.parse || module.exports;\nconsole.log(parse(\"**bold**\"));\n")

    assert out =~ "<strong>bold</strong>"
  end

  test "Porffor.Debug.diagnose returns named hot functions" do
    {:ok, report} =
      Nexus.Porffor.Debug.diagnose(
        File.read!(@prelude) <> "\nconsole.log(\"num=\" + (2 + 3));\n",
        fuel: 200_000_000,
        top: 5
      )

    assert report.completed
    assert report.output == "num=5\n"
    # names resolved from the wasm name section (not opaque indices)
    assert Enum.all?(report.hot, fn h -> is_binary(h.name) end)
    assert Enum.any?(report.hot, fn h -> String.starts_with?(h.name, "__Porffor") end)
  end
end
