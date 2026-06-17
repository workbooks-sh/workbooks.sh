defmodule Workbooks.ToolchainPalletTest do
  @moduledoc """
  The toolchain "pallet": a language runtime/compiler is a PINNED prebuilt wasm
  declared in a committed manifest (#+BUILD_SRC: wasm:<url> + #+SHA256), fetched +
  hash-verified + content-addressed + registered. Fast tests cover parsing + the
  fetch guards (no network); the :build-tagged tests actually fetch (network).
  """
  use ExUnit.Case, async: false

  alias Workbooks.{WorkKits, CommandRegistry}

  @root "../workkits"
  @qjs_url "https://github.com/quickjs-ng/quickjs/releases/download/v0.15.1/qjs-wasi.wasm"
  @qjs_sha "b4071ef2fbb2bb693c0bbcfc07cb9d28639fd9cea2fd986824a57aeac929817b"

  describe "manifest parsing (no network)" do
    test "wasm:<url> + sha256 parse into the descriptor" do
      body = """
      <work-ref rel="kit" name="qjs" cli="qjs" exec="command"
        build-src="wasm:#{@qjs_url}" sha256="#{@qjs_sha}" arg-mode="argv"/>
      <work-doc title="qjs"></work-doc>
      """

      d = WorkKits.parse_descriptor(body)
      assert d.build_src == {:wasm, @qjs_url}
      assert d.sha256 == @qjs_sha
      assert d.arg_mode == :argv
    end
  end

  describe "fetch_and_register_wasm guards (no network — rejected before any fetch)" do
    test "reserved built-in name is refused" do
      assert {:error, :reserved_name} = CommandRegistry.fetch_and_register_wasm("jq", @qjs_url, @qjs_sha)
    end

    test "invalid command name is refused" do
      assert {:error, :invalid_name} = CommandRegistry.fetch_and_register_wasm("../evil", @qjs_url, @qjs_sha)
    end

    test "non-https url is refused (no downgrade / file:)" do
      assert {:error, :invalid_url} =
               CommandRegistry.fetch_and_register_wasm("x", "file:///etc/passwd", @qjs_sha)

      assert {:error, :invalid_url} =
               CommandRegistry.fetch_and_register_wasm("x", "http://example.com/x.wasm", @qjs_sha)
    end
  end

  describe "pinned fetch + run (network)" do
    @tag :build
    test "a wrong sha pin is refused (supply-chain gate)" do
      bad = String.duplicate("0", 64)
      assert {:error, {:sha_mismatch, info}} =
               CommandRegistry.fetch_and_register_wasm("qjs_badpin", @qjs_url, bad)

      assert info[:got] == @qjs_sha
    end

    @tag :build
    test "work kit build palette qjs (one runtime from the set) fetches, verifies, registers, runs JS" do
      {:ok, _} = ensure_ready()
      out = WorkKits.build_text("palette", "qjs", @root)
      assert out =~ "registered command \"qjs\""
      assert "qjs" in CommandRegistry.list()

      # run real JS through the freshly-registered, sandboxed runtime
      tmp = Path.join(System.tmp_dir!(), "wbjs-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "a.js"), "console.log('sum', 19 + 23)")
      {:ok, js} = CommandRegistry.run("qjs", "", ["/w/a.js"], ["#{tmp}::/w"])
      assert js =~ "sum 42"
    end

    @tag :build
    test "work kit build palette python (archive runtime: wasm + stdlib) runs a .py" do
      {:ok, _} = ensure_ready()
      out = WorkKits.build_text("palette", "python", @root)
      assert out =~ "registered command \"python\""

      tmp = Path.join(System.tmp_dir!(), "wbpy-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "a.py"), "import math; print('fact', math.factorial(5))")
      {:ok, py} = CommandRegistry.run("python", "", ["/w/a.py"], ["#{tmp}::/w"])
      assert py =~ "fact 120"
    end

    @tag :build
    test "work kit build palette go (gobuild yaegi → wasip1) runs .go source" do
      {:ok, _} = ensure_ready()
      out = WorkKits.build_text("palette", "go", @root)
      assert out =~ "registered command \"go\""

      tmp = Path.join(System.tmp_dir!(), "wbgo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "a.go"), "package main\nimport \"fmt\"\nfunc main(){ fmt.Println(\"go\", 6*7) }\n")
      {:ok, go} = CommandRegistry.run("go", "", ["run", "/w/a.go"], ["#{tmp}::/w"])
      assert go =~ "go 42"
    end

    @tag :build
    @tag timeout: 300_000
    test "work kit build palette lua (wasi-sdk sjlj build) runs .lua incl. pcall/longjmp" do
      {:ok, _} = ensure_ready()
      out = WorkKits.build_text("palette", "lua", @root)
      assert out =~ "registered command \"lua\""

      tmp = Path.join(System.tmp_dir!(), "wbl-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      # This program exercises Lua's pcall (protected call), which catches a raised
      # error via setjmp/longjmp. In wasm there is no native setjmp/longjmp — it only
      # works because the Lua wasm is built with wasi-sdk's `-wasm-enable-sjlj`
      # (lowering longjmp to the standardized Wasm exception-handling proposal) AND is
      # run on wasmtime with `-W exceptions=y`. If sjlj were broken the guest would
      # TRAP/abort on `error(...)` instead of unwinding; here it must unwind cleanly:
      #   * pcall returns false (the error was caught, not fatal),
      #   * the error message is propagated back, and
      #   * execution CONTINUES past the protected call (longjmp resumed at setjmp).
      # We print with explicit string concatenation (one space) so the output format
      # is unambiguous and self-consistent with the assertions below.
      prog = """
      print('lua ' .. tostring(6*7))
      local ok, err = pcall(function() error('boom') end)
      print('pcall caught=' .. tostring(not ok) .. ' err=' .. tostring(err))
      print('after pcall still running')
      """

      File.write!(Path.join(tmp, "a.lua"), prog)
      {:ok, lua} = CommandRegistry.run("lua", "", ["/w/a.lua"], ["#{tmp}::/w"])
      assert lua =~ "lua 42"
      # pcall returned false → the raised error was CAUGHT by setjmp/longjmp (not fatal).
      assert lua =~ "pcall caught=true"
      # the error value was propagated through the longjmp, carrying Lua's position info.
      assert lua =~ "boom"
      # and the stack unwound back to the setjmp point, so the program kept running.
      assert lua =~ "after pcall still running"
    end

    @tag :build
    @tag timeout: 180_000
    test "work kit build palette zig (native zig → wasm command) runs a Zig-authored command" do
      {:ok, _} = ensure_ready()
      out = WorkKits.build_text("palette", "zig", @root)
      assert out =~ "registered command \"zigdemo\""
      {:ok, z} = CommandRegistry.run("zigdemo", "", [], [])
      assert z =~ "55"
    end
  end

  # The workbook reader (Workbooks.Workbook) is a plain Floki module now — no
  # kernel process to start. Kept as a {:ok, _} no-op so the call sites are intact.
  defp ensure_ready, do: {:ok, :no_kernel}
end
