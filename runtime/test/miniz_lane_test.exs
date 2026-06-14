defmodule Workbooks.MinizLaneTest do
  @moduledoc """
  Proves the miniz lane (zlib/gzip/ZIP archive handling, C→wasm32-wasip1): miniz compiles via build_c_dir and
  creates a ZIP archive in memory, reads it back, and extracts the entry — matching the original — in-sandbox.
  Source provisioned by compilers/miniz/build.sh (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/miniz/src"))

  @tag :build
  @tag timeout: 300_000
  test "miniz creates + reads + extracts a ZIP archive in-sandbox" do
    if not File.regular?(Path.join(@src, "miniz.c")) do
      IO.puts("\n[skip] miniz source not staged — run compilers/miniz/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, [])
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "files=1"
      assert out =~ "extract_match=1"
    end
  end
end
