defmodule Workbooks.TreesitterLaneTest do
  @moduledoc """
  Proves the tree-sitter lane (code → AST parsing, C→wasm32-wasip1): the tree-sitter runtime + the JSON grammar
  compile via build_c_dir and parse source into a typed syntax tree in-sandbox. Source provisioned by
  compilers/treesitter/build.sh (fetched, gitignored); skips if absent. (Other grammars drop in the same way.)
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/treesitter/src"))
  @inc ~w(alloc.c get_changed_ranges.c language.c lexer.c node.c parser.c query.c stack.c subtree.c tree_cursor.c tree.c wasm_store.c)

  @tag :build
  @tag timeout: 300_000
  test "tree-sitter parses source into a typed AST in-sandbox (JSON grammar)" do
    if not File.regular?(Path.join(@src, "lib.c")) do
      IO.puts("\n[skip] tree-sitter source not staged — run compilers/treesitter/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, ["-Wno-implicit-function-declaration"], @inc)
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "root=document"
      assert out =~ "array"      # [1,2,3] -> (document (array (number) (number) (number)))
      assert out =~ "number"
    end
  end
end
