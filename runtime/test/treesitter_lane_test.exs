defmodule Workbooks.TreesitterLaneTest do
  @moduledoc """
  Proves the tree-sitter lane (code → AST parsing, C→wasm32-wasip1): the tree-sitter runtime + the C grammar
  compile via build_c_dir and parse REAL C source into a typed syntax tree in-sandbox (translation_unit,
  function_definition, …). Any tree-sitter grammar swaps in the same way. Source provisioned by
  compilers/treesitter/build.sh (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/treesitter/src"))
  @inc ~w(alloc.c get_changed_ranges.c language.c lexer.c node.c parser.c query.c stack.c subtree.c tree_cursor.c tree.c wasm_store.c)

  @tag :build
  @tag timeout: 300_000
  test "tree-sitter parses real C source into a typed AST in-sandbox" do
    if not File.regular?(Path.join(@src, "lib.c")) do
      IO.puts("\n[skip] tree-sitter source not staged — run compilers/treesitter/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, ["-Wno-implicit-function-declaration"], @inc)
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "root=translation_unit"
      assert out =~ "has_func=1"     # function_definition recognized in the AST
    end
  end
end
