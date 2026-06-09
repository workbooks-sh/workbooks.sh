defmodule WasmShellTest do
  @moduledoc """
  End-to-end proof of the in-WASM shell (wb-9ja): the agent's shell runs real
  coreutils (wbox: echo/cat/seq/head/wc) compiled to wasm32-wasi via clang.wasm,
  orchestrated by Workbooks.Shell — NO OS process, NO fork/exec, no bash.

  Compiles C → wasm on first run (clang.wasm + wasm-ld), so it needs the in-repo
  compiler toolchain; tagged :wasm_e2e + skipped if the toolchain isn't present.
  """
  use ExUnit.Case, async: false
  @moduletag :wasm_e2e
  @moduletag timeout: 120_000

  @clang Path.expand("../compilers/clang/clang-root/llvm.core.wasm", __DIR__)

  setup_all do
    if File.exists?(@clang), do: :ok, else: {:skip, "clang toolchain not provisioned"}
  end

  test "real coreutils pipeline runs entirely in WASM" do
    # seq → head → wc, each a wbox applet in the sandbox; byte-exact piping means
    # wc -l counts the trailing newline correctly (regression: it used to undercount).
    assert {:ok, "3"} = Workbooks.Shell.run("seq 5 | head -n 3 | wc -l")
    assert {:ok, "3"} = Workbooks.Shell.run("seq 3 | wc -l")
  end

  test "wbox applets compose with the existing wasm commands" do
    assert {:ok, "HELLO WORLD"} = Workbooks.Shell.run("echo hello world | upper")
    assert {:ok, "3"} = Workbooks.Shell.run("echo -n abc | wc -c")
  end

  test "more coreutils applets + ; sequencing" do
    assert {:ok, "olleh"} = Workbooks.Shell.run("echo hello | rev")
    assert {:ok, "c"} = Workbooks.Shell.run("basename /a/b/c.txt .txt")
    assert {:ok, "/a/b"} = Workbooks.Shell.run("dirname /a/b/c.txt")
    assert {:ok, "heLLo"} = Workbooks.Shell.run("echo hello | tr l L")
    assert {:ok, "a\nb"} = Workbooks.Shell.run("echo a ; echo b")
  end

  test "trim: false preserves byte-exact command output (only the final result is trimmed)" do
    # The pipe must not strip a trailing newline mid-stream; standalone still trims.
    assert {:ok, "1\n2\n3\n"} = Workbooks.CommandRegistry.run("wbox", "", ["seq", "3"], [], trim: false)
    assert {:ok, "1\n2\n3"} = Workbooks.CommandRegistry.run("wbox", "", ["seq", "3"])
  end
end
