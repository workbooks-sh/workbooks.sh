defmodule Workbooks.XdiffLaneTest do
  @moduledoc """
  Proves the xdiff lane (text diffing — the git diff engine, C→wasm32-wasip1): xdiff compiles via build_c_dir
  (with a minimal git-xdiff.h shim) and produces a unified diff of two texts in-sandbox. Source provisioned by
  compilers/xdiff/build.sh (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/xdiff/src"))

  @tag :build
  @tag timeout: 300_000
  test "xdiff produces a unified diff in-sandbox" do
    if not File.regular?(Path.join(@src, "xdiffi.c")) do
      IO.puts("\n[skip] xdiff source not staged — run compilers/xdiff/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, [])
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "@@ -1,3 +1,3 @@"   # unified hunk header
      assert out =~ "-beta"
      assert out =~ "+BETA"
    end
  end
end
