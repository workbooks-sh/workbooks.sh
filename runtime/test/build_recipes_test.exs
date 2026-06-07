defmodule Workbooks.BuildRecipesTest do
  @moduledoc """
  P5 — per-language build recipes + content-addressed command artifacts + --help
  capture. Proves the real vertical, no stubs:
    - PackageManager.build_dir/2 builds a runnable Go (TinyGo wasip1) and JS (Javy)
      command from a real fixture dir; argv + stdin -> stdout works.
    - PackageManager.content_address/1 hashes the bytes into build/commands/<sha>.wasm
      and is idempotent (same source -> same path).
    - CommandRegistry.register_artifact/3 content-addresses on register.
    - PackageManager.capture_help/1 runs a built CLI with ["--help"] (huniq/sd,
      @tag :build — needs the rust wasm toolchain + network for cargo install).
  """
  use ExUnit.Case, async: false

  alias Workbooks.{PackageManager, CommandRegistry}

  @gocli Path.expand("fixtures/gocli", __DIR__)
  @jscli Path.expand("fixtures/jscli", __DIR__)

  test "build_dir Go fixture -> runnable wasip1 command (argv + stdin)" do
    assert {:ok, wasm, :built_dir} = PackageManager.build_dir(@gocli, "go")
    assert File.exists?(wasm)
    out = PackageManager.run(wasm, "alpha\nbeta\n", ["::"])
    assert out =~ ":: alpha"
    assert out =~ ":: beta"
  end

  test "build_dir JS fixture -> runnable command (stdin -> stdout)" do
    assert {:ok, wasm, :built} = PackageManager.build_dir(@jscli, "js")
    assert File.exists?(wasm)
    out = PackageManager.run(wasm, "abc\nXY\n", []) |> String.trim()
    assert out == "cba\nYX"
  end

  test "content_address is idempotent and lands in build/commands" do
    {:ok, wasm, :built_dir} = PackageManager.build_dir(@gocli, "go")
    assert {:ok, a1, sha1} = PackageManager.content_address(wasm)
    assert {:ok, a2, sha2} = PackageManager.content_address(wasm)
    assert sha1 == sha2
    assert a1 == a2
    assert a1 =~ "/build/commands/"
    assert Path.basename(a1) == "#{sha1}.wasm"
  end

  test "register_artifact content-addresses then registers a runnable command" do
    {:ok, wasm, :built_dir} = PackageManager.build_dir(@gocli, "go")
    assert {:ok, addressed} = CommandRegistry.register_artifact("p5-gocli", wasm, :argv)
    assert addressed =~ "/build/commands/"
    assert "p5-gocli" in CommandRegistry.list()
    assert {:ok, out} = CommandRegistry.run("p5-gocli", "one\ntwo\n", ["#"])
    assert out =~ "# one"
  end

  @tag :build
  @tag timeout: 420_000
  test "capture_help on huniq: build -> content-address -> --help" do
    assert {:ok, path} = CommandRegistry.build_and_register_crate("huniq", "huniq", :argv)
    assert path =~ "/build/commands/"
    help = PackageManager.capture_help(path)
    assert help =~ "Remove duplicates"
    assert help =~ "USAGE"
  end

  @tag :build
  @tag timeout: 420_000
  test "capture_help on sd: build -> content-address -> --help" do
    assert {:ok, path} = CommandRegistry.build_and_register_crate("sd", "sd", :argv)
    assert path =~ "/build/commands/"
    help = PackageManager.capture_help(path)
    assert help =~ "find & replace"
    assert help =~ "Usage"
  end
end
