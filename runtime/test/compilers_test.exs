defmodule Workbooks.CompilersTest do
  @moduledoc """
  Compiler-in-WASM framework (wb-zyl). A compiler in compilers/<lang>/ builds to a wasm
  command; untrusted source is compiled+run ENTIRELY in the sandbox (zero native execution).
  """
  use ExUnit.Case, async: false
  alias Workbooks.Compilers

  test "lists languages with a compilers/<lang>/manifest" do
    assert "c" in Compilers.list()
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
end
