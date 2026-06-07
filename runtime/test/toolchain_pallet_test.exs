defmodule Workbooks.ToolchainPalletTest do
  @moduledoc """
  The toolchain "pallet": a language runtime/compiler is a PINNED prebuilt wasm
  declared in a committed manifest (#+BUILD_SRC: wasm:<url> + #+SHA256), fetched +
  hash-verified + content-addressed + registered. Fast tests cover parsing + the
  fetch guards (no network); the :build-tagged tests actually fetch (network).
  """
  use ExUnit.Case, async: false

  alias Workbooks.{Toolkits, CommandRegistry}

  @root "../toolkits"
  @qjs_url "https://github.com/quickjs-ng/quickjs/releases/download/v0.15.1/qjs-wasi.wasm"
  @qjs_sha "b4071ef2fbb2bb693c0bbcfc07cb9d28639fd9cea2fd986824a57aeac929817b"

  describe "manifest parsing (no network)" do
    test "wasm:<url> + #+SHA256 parse into the descriptor" do
      body = """
      #+CLI_BIN: qjs
      #+EXEC: command
      #+BUILD_SRC: wasm:#{@qjs_url}
      #+SHA256: #{@qjs_sha}
      #+ARG_MODE: argv
      """

      d = Toolkits.parse_descriptor(body)
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
    test "wb toolkit build palette qjs (one runtime from the set) fetches, verifies, registers, runs JS" do
      {:ok, _} = ensure_oql()
      out = Toolkits.build_text("palette", "qjs", @root)
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
    test "wb toolkit build palette python (archive runtime: wasm + stdlib) runs a .py" do
      {:ok, _} = ensure_oql()
      out = Toolkits.build_text("palette", "python", @root)
      assert out =~ "registered command \"python\""

      tmp = Path.join(System.tmp_dir!(), "wbpy-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "a.py"), "import math; print('fact', math.factorial(5))")
      {:ok, py} = CommandRegistry.run("python", "", ["/w/a.py"], ["#{tmp}::/w"])
      assert py =~ "fact 120"
    end

    @tag :build
    test "wb toolkit build palette go (gobuild yaegi → wasip1) runs .go source" do
      {:ok, _} = ensure_oql()
      out = Toolkits.build_text("palette", "go", @root)
      assert out =~ "registered command \"go\""

      tmp = Path.join(System.tmp_dir!(), "wbgo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "a.go"), "package main\nimport \"fmt\"\nfunc main(){ fmt.Println(\"go\", 6*7) }\n")
      {:ok, go} = CommandRegistry.run("go", "", ["run", "/w/a.go"], ["#{tmp}::/w"])
      assert go =~ "go 42"
    end
  end

  defp ensure_oql do
    case Process.whereis(Workbooks.OQL) do
      nil -> Workbooks.OQL.start_link(nil)
      pid -> {:ok, pid}
    end
  end
end
