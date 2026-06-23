defmodule Nexus.WashyRealTest do
  @moduledoc """
  Washy running REAL clang-compiled C programs (our clang.wasm lane → wasm → Washy, pure Elixir,
  BEAM-isolated). Runs only when the C wasm lane is built; skips otherwise. This is the empirical driver
  that surfaces exactly which opcodes/WASI calls a real toolchain emits.
  """
  use ExUnit.Case, async: false

  defp compile(src) do
    p = Path.join(System.tmp_dir!(), "wreal#{System.unique_integer([:positive])}.c")
    File.write!(p, src)
    {:ok, wasm} = Nexus.Compilers.C.compile_to_wasm(p, shape: :command)
    {:ok, mod} = Nexus.Washy.decode(File.read!(wasm))
    mod
  end

  defp run(mod) do
    try do
      {_r, out} = Nexus.Washy.call_io(mod, "_start", [])
      {0, out}
    catch
      :throw, {:washy_exit, code} -> {code, Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary()}
    end
  end

  @tag timeout: 240_000
  test "a real clang-compiled C program runs end-to-end and returns its exit code" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) do
      {code, _out} = run(compile("int main(void){ return 42; }"))
      assert code == 42
    else
      IO.puts("\n[skip] C wasm lane not built")
    end
  end

  @tag timeout: 240_000
  test "a real C program with OUTPUT (data section + WASI write) prints correctly on Washy" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) do
      {code, out} = run(compile("#include <unistd.h>\nint main(void){ write(1, \"hi\\n\", 3); return 0; }"))
      assert out == "hi\n"
      assert code == 0
    else
      :ok
    end
  end

  @tag timeout: 240_000
  test "real C with FUNCTION POINTERS (call_indirect) + FLOATS computes correctly on Washy" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) do
      src = """
      #include <unistd.h>
      static int add(int a,int b){return a+b;}
      static int sub(int a,int b){return a-b;}
      int main(void){
        int (*ops[2])(int,int) = {add, sub};
        double d = 3.5 * 2.0;
        int r = ops[0](10,5) + ops[1](10,5) + (int)d;   // 15 + 5 + 7 = 27
        char buf[2]; buf[0]='0'+(r/10); buf[1]='0'+(r%10);
        write(1, buf, 2);
        return 0;
      }
      """
      {code, out} = run(compile(src))
      assert out == "27"
      assert code == 0
    else
      :ok
    end
  end

  @tag timeout: 240_000
  test "GENERALITY: real Rust (coreutils.wasm, 5289 funcs) runs `echo` on Washy" do
    wasm = "kits/coreutils.wasm"
    if File.exists?(wasm) do
      # proves Washy is a general wasm runtime, not C-specific: a 9.6MB Rust multicall
      # binary (SIMD, non-finite floats, 32 WASI imports) decodes + executes in pure Elixir.
      {:ok, mod} = Nexus.Washy.decode(File.read!(wasm))
      assert length(mod.code) > 5000
      Process.put(:washy_argv, ["echo", "hi"])
      Process.put(:washy_stdin, "")
      Process.put(:washy_vfs, %{})
      Process.put(:washy_fds, %{})
      Process.put(:washy_nextfd, 4)
      {_code, out} = run(mod)
      assert out == "hi\n"
    else
      IO.puts("\n[skip] coreutils.wasm not present")
    end
  end

  @tag timeout: 240_000
  test "THE SHELL runs on Washy — a featured shell (sh.c → wasm) executes a pipe in pure Elixir" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) do
      {:ok, wasm} = Nexus.Compilers.C.compile_to_wasm(Path.expand("priv/shell/sh.c"), shape: :command)
      {:ok, mod} = Nexus.Washy.decode(File.read!(wasm))
      Process.put(:washy_stdin, "echo hi | upper")
      Process.put(:washy_argv, ["sh"])
      {_code, out} = run(mod)
      assert out == "HI\n"
    else
      :ok
    end
  end

  @tag timeout: 240_000
  test "the shell does REAL file ops over Washy's virtual filesystem (in pure Elixir)" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) do
      {:ok, wasm} = Nexus.Compilers.C.compile_to_wasm(Path.expand("priv/shell/sh.c"), shape: :command)
      {:ok, mod} = Nexus.Washy.decode(File.read!(wasm))

      reset = fn vfs ->
        Process.put(:washy_vfs, vfs)
        Process.put(:washy_fds, %{})
        Process.put(:washy_nextfd, 4)
        Process.put(:washy_argv, ["sh"])
      end

      # READ a file from the virtual FS through a pipe
      reset.(%{"a.txt" => "banana\napple\ncherry\napple\n"})
      Process.put(:washy_stdin, "cat /work/a.txt | sort | uniq")
      {_c, out} = run(mod)
      assert out == "apple\nbanana\ncherry\n"

      # WRITE a file into the virtual FS via redirect
      reset.(%{})
      Process.put(:washy_stdin, "echo hello-vfs > /work/out.txt")
      run(mod)
      assert Process.get(:washy_vfs)["out.txt"] == "hello-vfs\n"

      # READ + grep + count
      reset.(%{"a.txt" => "banana\napple\ncherry\napple\n"})
      Process.put(:washy_stdin, "cat /work/a.txt | grep apple | wc -l")
      {_c2, out2} = run(mod)
      assert out2 == "2\n"
    else
      :ok
    end
  end

  @tag timeout: 240_000
  test "the shell does file ops over the TENANT-SCOPED SQLite-backed VFS (durable, isolated)" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) do
      {:ok, wasm} = Nexus.Compilers.C.compile_to_wasm(Path.expand("priv/shell/sh.c"), shape: :command)
      {:ok, mod} = Nexus.Washy.decode(File.read!(wasm))
      Nexus.Store.clear(Nexus.Washy.FileRow, "acme")

      reset = fn ->
        Process.put(:washy_backend, {:store, "acme"})
        Process.put(:washy_fds, %{})
        Process.put(:washy_nextfd, 4)
        Process.put(:washy_argv, ["sh"])
      end

      # the guest writes a file through WASI; it lands in tenant "acme"'s SQLite partition
      reset.()
      Process.put(:washy_stdin, "echo persisted-by-guest > /work/note.txt")
      run(mod)
      assert Nexus.Washy.VFS.get("note.txt") == "persisted-by-guest\n"

      # a DIFFERENT guest run reads it back from the store (durable across runs)
      reset.()
      Process.put(:washy_stdin, "cat /work/note.txt | upper")
      {_c, out} = run(mod)
      assert out == "PERSISTED-BY-GUEST\n"

      # tenant "other" cannot see acme's bytes — same path, disjoint store
      Process.put(:washy_backend, {:store, "other"})
      assert Nexus.Washy.VFS.get("note.txt") == nil
      Process.delete(:washy_backend)
    else
      :ok
    end
  end
end
