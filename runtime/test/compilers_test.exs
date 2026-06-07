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
      # execution) and emits C. End-to-end run chains the emitted C through the C lane
      # (tcc.wasm) — see compilers/zig/README.org for the honest status.
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
  end
end
