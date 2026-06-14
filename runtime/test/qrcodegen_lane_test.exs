defmodule Workbooks.QrcodegenLaneTest do
  @moduledoc """
  Proves the qrcodegen lane (QR code generation, C→wasm32-wasip1): nayuki's single-file QR generator compiles via
  build_c_dir and encodes a URL into a QR module matrix in-sandbox. Source provisioned by
  compilers/qrcodegen/build.sh (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/qrcodegen/src"))

  @tag :build
  @tag timeout: 300_000
  test "qrcodegen encodes a URL into a QR module matrix in-sandbox" do
    if not File.regular?(Path.join(@src, "qrcodegen.c")) do
      IO.puts("\n[skip] qrcodegen source not staged — run compilers/qrcodegen/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, [])
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "qr_ok=1"
      assert out =~ "size=25"        # version-2 QR for the URL
      assert out =~ "corner=1"       # finder-pattern dark corner
      refute out =~ "dark=0"
    end
  end
end
