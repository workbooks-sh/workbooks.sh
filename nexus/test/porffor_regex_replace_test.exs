defmodule Nexus.PorfforRegexReplaceTest do
  @moduledoc """
  Guards the regex/replace correctness fixes that unblocked marked bold/em rendering + heading slugs on the
  Porffor→Washy lane (and the durable debug tool that found them). Each ran byte-identical to node before
  being asserted.

  - RegExp flag accessors (`ignoreCase`/`multiline`/`dotAll`/`sticky`): the `& mask` result (2,4,8,…) only
    kept bit 0, so only `global` worked. Fixed with `!= 0` normalization (regexp.ts).
  - `String#replace(re, "$1")` $-templates: the old `split().join()` shim emitted the literal "$1" and
    dropped captures, corrupting marked's grammar regex. Fixed with a template-aware exec loop (spread_desugar).
  - `i32.trunc_sat` of NaN/±Inf fed a `{:nonfinite}` tuple into a bitwise op → ArithmeticError (marked's
    emStrong produces NaN). Now saturates per spec (washy.ex).
  - `RegExp.lastIndex` setter was missing → `re.lastIndex = 0` was a no-op → a reused global regex kept a
    stale lastIndex (only the FIRST emStrong match correct). Fixed in `__Porffor_object_set*` (regexp store
    to mem offset 8).
  - char-class range endpoints stored in a single byte → `\\u2000`→0x00 made `[\\u2000-\\u206F]` match all
    ASCII (marked heading `id=""`). Clamp >255 endpoints so they never falsely match a byte (regexp.ts).

  Many fixes live in untracked builtins (regexp.ts / _internal_object.ts; ship via the compilers publish) —
  this test is their tracked regression guard.
  """
  use ExUnit.Case, async: false

  alias Nexus.Compilers.Js.Porffor

  @prelude Path.join(__DIR__, "conformance/porffor_cjs/cjs_prelude.js")

  setup_all do
    if File.regular?(Porffor.porf_entry()) and System.find_executable("node"),
      do: :ok,
      else: {:skip, "porffor/node absent"}
  end

  # Run JS on the lazy-transpile ASM lane via the debug tool (NOT Sandbox.run_command, which prewarms and
  # currently miscompiles — G5). Returns captured stdout.
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

  test "char-class with non-ASCII (>255) range endpoints does not falsely match ASCII (slugger)" do
    # Endpoints were stored in a single byte:   → 0x00 made [ -⁯] match all ASCII, so marked
    # heading id="". This is marked's serialize() chain verbatim, written with the real \u escapes.
    out =
      run(
        "var slug = \"Hello World\".toLowerCase().trim()" <>
          ".replace(/<[!\\/a-z].*?>/gi,\"\")" <>
          ".replace(/[\\u2000-\\u206F\\u2E00-\\u2E7F\\\\'!\\\"#$%&()*+,.\\/:;<=>?@[\\]^`{|}~]/g,\"\")" <>
          ".replace(/\\s/g,\"-\");\nconsole.log(slug);\n"
      )

    assert out == "hello-world\n"
  end

  test "String#replace with $1 capture template expands (not literal)" do
    out =
      run(~S"""
      console.log("x`^y".replace(/(^|[^\[])\^/g, "$1"));
      console.log("a^b".replace(/(a)\^/g, "[$1]"));
      """)

    assert out == "x`y\n[a]b\n"
  end

  test "marked emphasis corpus is byte-identical to node on BOTH interp and ASM lanes" do
    marked = File.read!(Path.join(__DIR__, "conformance/marked-4.3.0.js"))

    driver =
      marked <>
        ~S"""

        ;
        var p = module.exports.parseInline;
        console.log(p("*em*") + "|" + p("_em_") + "|" + p("**b**") + "|" + p("***x***") + "|" + p("a *b* c"));
        """

    # node golden (the oracle); the lastIndex-setter + $1-template + flag-accessor fixes made these match.
    want = "<em>em</em>|<em>em</em>|<strong>b</strong>|<em><strong>x</strong></em>|a <em>b</em> c\n"

    src = File.read!(@prelude) <> "\n" <> driver

    for transpile <- [false, true] do
      {:ok, r} = Nexus.Porffor.Debug.diagnose(src, fuel: 1_000_000_000, transpile: transpile)
      assert r.completed, "lane transpile=#{transpile} did not complete: #{inspect(r.trap || r.error)}"
      assert r.output == want, "lane transpile=#{transpile} mismatch:\n got #{inspect(r.output)}\nwant #{inspect(want)}"
    end
  end

  test "self-referential multi-declarator var keeps earlier-assigned values (marked list regex)" do
    # Porffor re-zero-inited a var at its own declarator, wiping a value assigned earlier in the same
    # `var` statement — `var p=1<(g="X").length, q={}, g="lit-"+g` gave `g="lit-undefined"`. arguments_desugar
    # now splits such declarations into hoisted name + sequential assignments (equivalent under hoisting).
    out =
      run(~S"""
      function f(){ var p = 1 < (g = "X").length, q = {a:1}, g = p ? "ord" : "lit-" + g; return "g="+g; }
      function h(){ var a = (b = 5) + 1, b = b * 2; return "b="+b; }
      console.log(f() + " " + h());
      """)

    assert out == "g=lit-X b=10\n"
  end

  test "marked lists + ordered lists render byte-identical on the ASM lane" do
    marked = File.read!(Path.join(__DIR__, "conformance/marked-4.3.0.js"))
    src =
      File.read!(@prelude) <>
        "\n" <> marked <>
        "\n;\nvar p=module.exports.parse;console.log(JSON.stringify(p(\"- a\\n- b\\n- c\"))+\"|\"+JSON.stringify(p(\"1. one\\n2. two\")));\n"

    {:ok, r} = Nexus.Porffor.Debug.diagnose(src, fuel: 2_000_000_000, transpile: true)
    assert r.completed, "did not complete: #{inspect(r.trap || r.error)}"

    want =
      ~S("<ul>\n<li>a</li>\n<li>b</li>\n<li>c</li>\n</ul>\n"|"<ol>\n<li>one</li>\n<li>two</li>\n</ol>\n") <> "\n"

    assert r.output == want
  end

  test "marked heading renders byte-identical with a slug id on the ASM lane" do
    marked = File.read!(Path.join(__DIR__, "conformance/marked-4.3.0.js"))
    src = File.read!(@prelude) <> "\n" <> marked <> "\n;\nconsole.log(module.exports.parse(\"# Hello World\"));\n"

    {:ok, r} = Nexus.Porffor.Debug.diagnose(src, fuel: 1_000_000_000, transpile: true)
    assert r.completed, "did not complete: #{inspect(r.trap || r.error)}"
    # node: <h1 id="hello-world">Hello World</h1>\n  (+ console.log's trailing \n)
    assert r.output == "<h1 id=\"hello-world\">Hello World</h1>\n\n"
  end
end
