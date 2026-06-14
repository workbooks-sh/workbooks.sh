defmodule Workbooks.Md4cLaneTest do
  @moduledoc """
  Proves the md4c lane (Markdown → HTML, C→wasm32-wasip1): the CommonMark parser/renderer compiles via
  build_c_dir and renders markdown to HTML in-sandbox (headings, emphasis, links). Source provisioned by
  compilers/md4c/build.sh (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/md4c/src"))

  @tag :build
  @tag timeout: 300_000
  test "md4c renders Markdown to HTML in-sandbox" do
    if not File.regular?(Path.join(@src, "md4c.c")) do
      IO.puts("\n[skip] md4c source not staged — run compilers/md4c/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, [])
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "<h1>Hello</h1>"
      assert out =~ "<strong>bold</strong>"
      assert out =~ ~s(<a href="http://x">link</a>)
    end
  end
end
