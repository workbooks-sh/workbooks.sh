defmodule Workbooks.CompilersTest do
  @moduledoc """
  Compiler-in-WASM framework (wb-zyl). A compiler in compilers/<lang>/ builds to a wasm
  command; untrusted source is compiled+run ENTIRELY in the sandbox (zero native execution).
  """
  use ExUnit.Case, async: false
  alias Workbooks.Compilers

  test "lists languages with a compilers/<lang>/manifest" do
    langs = Compilers.list()
    assert "c" in langs
    assert "zig" in langs
    assert "clang" in langs
  end

  describe "C compiler in the sandbox (c4)" do
    @tag :build
    @tag timeout: 120_000
    test "builds the C compiler to wasm and compiles+runs untrusted C in-sandbox" do
      assert {:ok, "c4", wasm} = Compilers.build("c")
      assert File.regular?(wasm)

      tmp = Path.join(System.tmp_dir!(), "cw-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "p.c"), "int main(){ printf(\"sum %d\\n\", 19+23); return 0; }")
      {:ok, out} = Compilers.compile_run("c", Path.join(tmp, "p.c"), [])
      assert out =~ "sum 42"
      # the compiler ran IN wasm — only the source dir was preopened (containment is the
      # same preopen boundary proven across the palette + the c4 spike "could not open").
    end
  end

  describe "Zig compiler in the sandbox (zig1.wasm)" do
    @tag :build
    @tag timeout: 300_000
    test "builds zig1.wasm and compiles untrusted .zig → C entirely in-sandbox" do
      # zig1.wasm runs the FULL zig frontend + Sema + C-backend INSIDE wasm (zero native
      # execution) and emits C. The end-to-end run (below) chains this through clang.wasm.
      assert {:ok, "zig1", wasm} = Compilers.build("zig")
      assert File.regular?(wasm)

      tmp = Path.join(System.tmp_dir!(), "zw-#{System.unique_integer([:positive])}.zig")

      File.write!(
        tmp,
        ~s|const std = @import("std");\npub fn main() void { std.debug.print("z={d}\\n", .{6 * 7}); }\n|
      )

      assert {:ok, c, _log} = Compilers.compile("zig", tmp)
      # genuine zig C-backend output (not a stub): its runtime header + size asserts.
      assert String.contains?(c, "zig.h")
      assert String.contains?(c, "zig_static_assert")
      assert byte_size(c) > 10_000
    end

    @tag :build
    @tag timeout: 600_000
    test "END-TO-END: untrusted .zig compiled AND run entirely in the sandbox" do
      # zig1.wasm (.zig→C) → clang.wasm (C+wasi-shim→object) → wasm-ld (link→wasm) → run.
      # Every stage in wasm; zero native execution.
      {:ok, _, _} = Compilers.build("zig")
      {:ok, _, _} = Compilers.build("clang")

      tmp = Path.join(System.tmp_dir!(), "ze2e-#{System.unique_integer([:positive])}.zig")

      File.write!(
        tmp,
        ~s|const std = @import("std");\npub fn main() void { std.debug.print("zig-e2e={d}\\n", .{6 * 7}); }\n|
      )

      assert {:ok, out} = Compilers.zig_compile_and_run(tmp)
      assert out =~ "zig-e2e=42"
    end
  end

  describe "full C/C++ compiler in the sandbox (clang+lld → wasm)" do
    @tag :build
    @tag timeout: 600_000
    test "builds clang.wasm and compiles+links+runs untrusted C entirely in-sandbox" do
      # YoWASP clang/lld (LLVM built FOR wasm32-wasi). clang -c then wasm-ld, both in wasm;
      # the emitted wasm runs in wasm. The production full-C lane (vs c4's interpreted subset).
      assert {:ok, "clang", core} = Compilers.build("clang")
      assert File.regular?(core)

      src = Path.join(System.tmp_dir!(), "fc-#{System.unique_integer([:positive])}.c")

      File.write!(
        src,
        "#include <stdio.h>\nint main(){ long f=1; for(int i=1;i<=10;i++) f*=i; printf(\"10!=%ld\\n\", f); return 0; }"
      )

      assert {:ok, out} = Compilers.compile_and_run_c(src)
      assert out =~ "10!=3628800"
    end
  end
end
