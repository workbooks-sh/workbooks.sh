defmodule Workbooks.BuildToToolTest do
  @moduledoc """
  Proves the SOURCE -> SANDBOXED-CLI-TOOL pipeline end to end: a real, self-contained C program is compiled to
  wasm ENTIRELY in-sandbox (Compilers.compile_c / clang.wasm, zero native execution) and then RUN sandboxed
  (wasmtime, stdin->stdout, no network) via the brokered execution path. This is the reclaim recipe for the
  self-contained-C class of build-blocked tools: arbitrary single-source C utilities become working sandboxed
  commands without any native toolchain.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, PackageManager}

  @tag :build
  @tag timeout: 300_000
  test "a self-contained C stats tool is compiled in-sandbox and runs sandboxed (stdin -> stdout)" do
    # a genuinely useful, non-trivial, self-contained CLI: read numbers from stdin, emit count/sum/min/max/mean.
    src = Path.join(System.tmp_dir!(), "stats_#{System.unique_integer([:positive])}.c")

    File.write!(src, ~S|
#include <stdio.h>
int main(void) {
  double x, sum = 0, mn = 1e300, mx = -1e300; long n = 0;
  while (scanf("%lf", &x) == 1) { sum += x; if (x < mn) mn = x; if (x > mx) mx = x; n++; }
  if (n == 0) { printf("count=0\n"); return 0; }
  printf("count=%ld sum=%g min=%g max=%g mean=%g\n", n, sum, mn, mx, sum / n);
  return 0;
}
|)

    on_exit(fn -> File.rm(src) end)

    # COMPILE in-sandbox (clang.wasm) -> a wasi CLI module
    assert {:ok, wasm, _} = Compilers.compile_c(src)
    on_exit(fn -> File.rm(wasm) end)

    # RUN sandboxed (wasmtime, no network, stdin -> stdout) — the same brokered execution lane commands use
    out = PackageManager.run(wasm, "3\n1\n4\n1\n5\n", [])
    out = if is_tuple(out), do: elem(out, 0), else: out

    assert out =~ "count=5"
    assert out =~ "sum=14"
    assert out =~ "min=1"
    assert out =~ "max=5"
    assert out =~ "mean=2.8"
  end
end
