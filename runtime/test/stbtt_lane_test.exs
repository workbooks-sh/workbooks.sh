defmodule Workbooks.StbttLaneTest do
  @moduledoc """
  Proves the stb_truetype lane (font rasterization, C→wasm32-wasip1): a TrueType font (read on stdin) is parsed
  and a glyph is rasterized to a bitmap in-sandbox (non-empty ink). Source provisioned by compilers/stbtt/build.sh
  (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/stbtt/src"))

  @tag :build
  @tag timeout: 300_000
  test "stb_truetype rasterizes a glyph from a TTF in-sandbox" do
    if not File.regular?(Path.join(@src, "stb_truetype.h")) or not File.regular?(Path.join(@src, "font.ttf")) do
      IO.puts("\n[skip] stb_truetype source/font not staged — run compilers/stbtt/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, [], ["font.ttf"])
      on_exit(fn -> File.rm(wasm) end)
      ttf = File.read!(Path.join(@src, "font.ttf"))
      out = PackageManager.run(wasm, ttf, [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ ~r/glyph_A w=\d+ h=\d+ ink_pixels=\d+/
      refute out =~ "ink_pixels=0"   # the rasterized glyph has ink
    end
  end
end
