defmodule Workbooks.JsEngineFallbackTest do
  @moduledoc """
  Proves `JsEngine.run_program/2` — the GENERAL JS/TS execution path — routes StarlingMonkey-first with a
  thin QuickJS fallback (the decision: SpiderMonkey is the default engine; QuickJS covers only its one gap).

  Two complementary engines, each proving one half of the routing, NO network needed:
    * StarlingMonkey path — `crypto.randomUUID()` (WebCrypto) runs on SM. QuickJS has no WebCrypto, so a
      pass here means SM served it. (uuid/nanoid — the libs that fail on bare QuickJS — ride this path.)
    * QuickJS fallback — `/[\\p{L}]/u` (regex unicode-property escape) makes SM's bootstrap return
      "ERR: … regular expression"; `run_program` must fall back to QuickJS, which handles `\\p{}`.
      (marked-class libraries ride this path.)

  Skips unless both engine artifacts are built (the SM eval-host + the QuickJS clang lane) — same cadence
  as the other :build lane tests.
  """
  use ExUnit.Case, async: false
  alias Workbooks.JsEngine

  @clang Path.expand(Path.join(__DIR__, "../compilers/clang/clang-root/llvm.core.wasm"))

  setup_all do
    # SM eval-host (built/cached by componentize-js) must exist, and the QuickJS fallback needs clang.wasm.
    sm = match?({:ok, _}, JsEngine.build_host())
    {:ok, sm?: sm and File.regular?(@clang)}
  end

  @tag :build
  @tag timeout: 300_000
  test "StarlingMonkey serves WebCrypto (default path)", %{sm?: ok?} do
    if not ok? do
      IO.puts("\n[skip] JS engines not built (SM eval-host / clang.wasm)")
    else
      # crypto.randomUUID is WebCrypto — present on StarlingMonkey, absent on bare QuickJS. A correct
      # 36-char UUID proves SM served the program (no fallback needed for the common case).
      assert {:ok, out} = JsEngine.run_program(~s|console.log(crypto.randomUUID().length)|)
      assert String.trim(out) == "36"
    end
  end

  @tag :build
  @tag timeout: 300_000
  test "QuickJS fallback covers SM's \\p{} regex gap", %{sm?: ok?} do
    if not ok? do
      IO.puts("\n[skip] JS engines not built (SM eval-host / clang.wasm)")
    else
      prog = ~S|console.log(/[\p{L}]/u.test("a"))|

      # 1. The gap is real: SM's bootstrap surfaces \p{} as an "ERR: … regular expression".
      assert {:ok, "ERR: " <> msg} = JsEngine.eval(prog)
      assert msg =~ "regular expression"

      # 2. run_program detects that and falls back to QuickJS, which evaluates \p{} correctly → "true".
      assert {:ok, out} = JsEngine.run_program(prog)
      assert String.trim(out) == "true"
    end
  end
end
