defmodule Workbooks.Pcre2LaneTest do
  @moduledoc """
  Proves the PCRE2 (Perl-compatible regex) lane (C→wasm32-wasip1): the 8-bit PCRE2 library compiles via
  build_c_dir and matches a pattern with capture groups in-sandbox. Source provisioned by compilers/pcre2/build.sh
  (fetched, gitignored); skips if absent.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager
  @src Path.expand(Path.join(__DIR__, "../compilers/pcre2/src"))
  @inc ["pcre2_ucptables.c", "pcre2_jit_match.c", "pcre2_jit_misc.c"]

  @tag :build
  @tag timeout: 300_000
  test "PCRE2 compiles a regex + extracts capture groups in-sandbox" do
    if not File.regular?(Path.join(@src, "pcre2_compile.c")) do
      IO.puts("\n[skip] PCRE2 source not staged — run compilers/pcre2/build.sh")
    else
      assert {:ok, wasm, _} = PackageManager.build_c_dir(@src, ["-DPCRE2_CODE_UNIT_WIDTH=8", "-DHAVE_CONFIG_H"], @inc)
      on_exit(fn -> File.rm(wasm) end)
      out = PackageManager.run(wasm, "", [])
      out = if is_tuple(out), do: elem(out, 0), else: out
      assert out =~ "match g1=user g2=host"   # (\w+)@(\w+) on "user@host"
    end
  end
end
