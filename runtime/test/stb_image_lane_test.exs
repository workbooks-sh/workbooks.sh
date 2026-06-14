defmodule Workbooks.StbImageLaneTest do
  @moduledoc """
  Proves the stb_image lane (image decoding, C->wasm32-wasip1): the single-header decoder compiles via build_c_dir
  and decodes a PNG (on stdin) to dimensions + RGBA pixels in-sandbox. Source provisioned by
  compilers/stb/build.sh (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/stb/src"))
  @png Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=")

  @tag :build
  @tag timeout: 300_000
  test "stb_image decodes a PNG to dimensions + pixels in-sandbox" do
    if not File.regular?(Path.join(@src, "stb_image.h")) do
      IO.puts("[skip] stb_image source not staged")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, [])
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, @png, [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "w=2 h=2 ch=4"
      assert out =~ "r0=255 g0=0 b0=0"
    end
  end
end
