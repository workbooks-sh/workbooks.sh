defmodule Workbooks.GumboLaneTest do
  @moduledoc """
  Proves the gumbo lane (HTML5 parsing, C→wasm32-wasip1): gumbo-parser compiles via build_c_dir and parses an
  HTML document into a DOM tree, extracting element text in-sandbox. Source provisioned by compilers/gumbo/build.sh
  (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/gumbo/src"))

  @tag :build
  @tag timeout: 300_000
  test "gumbo parses HTML to a DOM and extracts element text in-sandbox" do
    if not File.regular?(Path.join(@src, "parser.c")) do
      IO.puts("\n[skip] gumbo source not staged — run compilers/gumbo/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, [])
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "h1=Hello Forge"
      assert out =~ "p=world"
    end
  end
end
