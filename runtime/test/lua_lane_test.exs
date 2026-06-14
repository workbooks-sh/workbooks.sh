defmodule Workbooks.LuaLaneTest do
  @moduledoc """
  Proves the Lua lane (full Lua 5.4 scripting language, C→wasm32-wasip1): the reference Lua interpreter compiles
  from source via build_c_dir (the in-sandbox clang lane, 33 C files) and runs scripts — arithmetic, the math
  stdlib, loops, io. Source provisioned by compilers/lua/build.sh (fetched, gitignored); skips if not staged.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/lua/src"))

  @tag :build
  @tag timeout: 300_000
  test "Lua interpreter compiles from source + runs a script (arithmetic/math/loop)" do
    if not File.regular?(Path.join(@src, "lua.c")) do
      IO.puts("\n[skip] Lua source not staged — run compilers/lua/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, [])
      on_exit(fn -> File.rm(wasm) end)

      r = PackageManager.run(wasm, "", ["-e", ~s|print("hi", 2+3, math.sqrt(16)); for i=1,3 do io.write(i*i," ") end|])
      out = if is_tuple(r), do: elem(r, 0), else: r
      assert out =~ "hi"
      assert out =~ "5"          # 2+3
      assert out =~ "4.0"        # math.sqrt(16)
      assert out =~ "1 4 9"      # loop i*i
    end
  end
end
