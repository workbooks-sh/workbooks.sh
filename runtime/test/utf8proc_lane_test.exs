defmodule Workbooks.Utf8procLaneTest do
  @moduledoc """
  Proves the utf8proc lane (Unicode normalization, C→wasm32-wasip1): utf8proc compiles via build_c_dir and
  case-folds + NFC-composes UTF-8 text in-sandbox (HeLLo→hello; e+U+0301→é). Source provisioned by
  compilers/utf8proc/build.sh (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/utf8proc/src"))

  @tag :build
  @tag timeout: 300_000
  test "utf8proc case-folds + NFC-normalizes UTF-8 in-sandbox" do
    if not File.regular?(Path.join(@src, "utf8proc.c")) do
      IO.puts("\n[skip] utf8proc source not staged — run compilers/utf8proc/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, [], ["utf8proc_data.c"])
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "casefold=hello"      # case-folding
      assert out =~ "nfc_bytes=c3a9"      # e + combining acute -> é (U+00E9, UTF-8 c3a9)
    end
  end
end
