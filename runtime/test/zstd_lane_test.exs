defmodule Workbooks.ZstdLaneTest do
  @moduledoc """
  Proves the zstd lane (compression, C→wasm32-wasip1): the zstd single-file amalgamation compiles via
  build_c_dir (in-sandbox clang) and a driver does a compress→decompress roundtrip, asserting the decompressed
  bytes equal the source. Source provisioned by compilers/zstd/build.sh (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/zstd/src"))

  @tag :build
  @tag timeout: 300_000
  test "zstd compress→decompress roundtrip in-sandbox" do
    if not File.regular?(Path.join(@src, "zstd_single.c")) do
      IO.puts("\n[skip] zstd source not staged — run compilers/zstd/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, [])
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "match=1"                 # decompressed == original
      assert out =~ ~r/comp=\d+/
    end
  end
end
