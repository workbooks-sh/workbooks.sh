defmodule Workbooks.XxhashLaneTest do
  @moduledoc """
  Proves the xxHash lane (fast non-cryptographic hashing, C→wasm32-wasip1): the single-header xxHash compiles via
  build_c_dir and computes deterministic XXH32/XXH64/XXH3 digests in-sandbox (content-addressing, dedup,
  checksums). Source provisioned by compilers/xxhash/build.sh (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/xxhash/src"))

  @tag :build
  @tag timeout: 300_000
  test "xxHash computes deterministic XXH32/64/XXH3 digests in-sandbox" do
    if not File.regular?(Path.join(@src, "xxhash.h")) do
      IO.puts("\n[skip] xxHash source not staged — run compilers/xxhash/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, [])
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "xxh64=fda087eddf672be9"
      assert out =~ "xxh32=b6e02b92"
      assert out =~ "xxh3=248a66b67c86cb78"
    end
  end
end
