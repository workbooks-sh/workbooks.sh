defmodule Workbooks.MinigmpLaneTest do
  @moduledoc """
  Proves the mini-gmp lane (arbitrary-precision integer math, C→wasm32-wasip1): the single-file GMP subset
  compiles via build_c_dir and computes exact big-integer results (2^200, 30!) in-sandbox. Source provisioned by
  compilers/minigmp/build.sh (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/minigmp/src"))

  @tag :build
  @tag timeout: 300_000
  test "mini-gmp computes exact arbitrary-precision integers in-sandbox (2^200, 30!)" do
    if not File.regular?(Path.join(@src, "mini-gmp.c")) do
      IO.puts("\n[skip] mini-gmp source not staged — run compilers/minigmp/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, [])
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "pow=1606938044258990275541962092341162602522202993782792835301376"   # 2^200
      assert out =~ "fact=265252859812191058636308480000000"                              # 30!
    end
  end
end
