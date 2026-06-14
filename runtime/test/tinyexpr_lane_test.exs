defmodule Workbooks.TinyexprLaneTest do
  @moduledoc """
  Proves the tinyexpr lane (math-expression evaluator, C→wasm32-wasip1): tinyexpr compiles via build_c_dir and
  evaluates math expressions with functions + bound variables in-sandbox. Source provisioned by
  compilers/tinyexpr/build.sh (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/tinyexpr/src"))

  @tag :build
  @tag timeout: 300_000
  test "tinyexpr evaluates expressions + bound variables in-sandbox" do
    if not File.regular?(Path.join(@src, "tinyexpr.c")) do
      IO.puts("\n[skip] tinyexpr source not staged — run compilers/tinyexpr/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, [])
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "a=11"   # 3+4*2
      assert out =~ "b=11"   # sqrt(9)+pow(2,3)
      assert out =~ "c=11" and out =~ "d=21"   # 2*x+1 with x=5 then x=10
    end
  end
end
