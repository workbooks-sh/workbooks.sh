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

  test "shell commands read preopened files (sandboxed fs access)" do
    dir = Path.join(System.tmp_dir!(), "wbfs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "f.txt"), "a\nb\nc\n")
    pre = ["#{dir}::#{dir}"]
    assert {:ok, "a\nb\nc"} = Workbooks.Shell.run("cat #{dir}/f.txt", "", dirs: pre)
    assert {:ok, "3"} = Workbooks.Shell.run("cat #{dir}/f.txt | wc -l", "", dirs: pre)
    assert {:ok, "b"} = Workbooks.Shell.run("cat #{dir}/f.txt | grep b", "", dirs: pre)
  end

  test "compiled C commands can use buffered stdio + large stack buffers (8MB stack)" do
    # Regression: a 64KB auto buffer used to blow the 64KB default stack, and
    # buffered FILE* stdio (getchar/putchar/printf) trapped. The 8MB stack fixes both.
    src = ~S|#include <stdio.h>
int main(){ char big[65536]; big[65535]=42; int c,n=0; while((c=getchar())!=EOF){putchar(c); if(c=='\n')n++;} printf("[%d %d]\n", n, big[65535]); return 0; }|
    assert {:ok, _} = Workbooks.CommandRegistry.build_and_register_inline("stdio_probe", "c", src)
    assert {:ok, "x\ny\n[2 42]"} = Workbooks.CommandRegistry.run("stdio_probe", "x\ny\n", [])
  end

  test "trim: false preserves byte-exact command output (only the final result is trimmed)" do
    # The pipe must not strip a trailing newline mid-stream; standalone still trims.
    assert {:ok, "1\n2\n3\n"} = Workbooks.CommandRegistry.run("wbox", "", ["seq", "3"], [], trim: false)
    assert {:ok, "1\n2\n3"} = Workbooks.CommandRegistry.run("wbox", "", ["seq", "3"])
  end
end
