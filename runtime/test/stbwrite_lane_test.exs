defmodule Workbooks.StbwriteLaneTest do
  @moduledoc """
  Proves the stb_image_write lane (image encoding/generation, C→wasm32-wasip1): pixels are encoded to a PNG and
  decoded back (with stb_image), verifying dimensions + pixels round-trip in-sandbox. Source provisioned by
  compilers/stbwrite/build.sh (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/stbwrite/src"))

  @tag :build
  @tag timeout: 300_000
  test "stb_image_write encodes pixels to PNG (roundtrips through decode) in-sandbox" do
    if not File.regular?(Path.join(@src, "stb_image_write.h")) do
      IO.puts("\n[skip] stb_image_write source not staged — run compilers/stbwrite/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, [])
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "w=2 h=2 ch=4"
      assert out =~ "r=255 g=128 b=0"   # encoded orange survives encode->decode
    end
  end
end
