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

  @tag :build
  @tag timeout: 300_000
  test "MULTI-STAGE build: an in-sandbox CODEGEN tool emits C source that is then compiled + run (codegen recipe)" do
    # This is the reclaim recipe for the codegen-blocked C class (bash's mkbuiltins, etc.): a build needs a
    # GENERATOR program compiled + RUN to emit .c/.h, which is then compiled into the final tool. Both stages
    # run ENTIRELY in-sandbox (clang.wasm + wasmtime), no native toolchain.

    # STAGE 1 — compile + run a codegen tool that emits a C lookup table to stdout.
    gen = Path.join(System.tmp_dir!(), "gen_#{System.unique_integer([:positive])}.c")

    File.write!(gen, ~S|
#include <stdio.h>
int main(void) {
  printf("static const int squares[10] = {");
  for (int i = 0; i < 10; i++) printf("%d,", i * i);
  printf("};\n");
  return 0;
}
|)

    on_exit(fn -> File.rm(gen) end)
    assert {:ok, gen_wasm, _} = Compilers.compile_c(gen)
    on_exit(fn -> File.rm(gen_wasm) end)

    generated = PackageManager.run(gen_wasm, "", [])
    generated = if is_tuple(generated), do: elem(generated, 0), else: generated
    assert generated =~ "static const int squares[10] = {0,1,4,9,16,25,36,49,64,81,};"

    # STAGE 2 — compile a final tool that uses the GENERATED source, then run it sandboxed.
    main = Path.join(System.tmp_dir!(), "usegen_#{System.unique_integer([:positive])}.c")

    File.write!(main, "#include <stdio.h>\n" <> generated <> ~S|
int main(void) { int x; if (scanf("%d", &x) == 1 && x >= 0 && x < 10) printf("%d\n", squares[x]); return 0; }
|)

    on_exit(fn -> File.rm(main) end)
    assert {:ok, main_wasm, _} = Compilers.compile_c(main)
    on_exit(fn -> File.rm(main_wasm) end)

    out = PackageManager.run(main_wasm, "7\n", [])
    out = if is_tuple(out), do: elem(out, 0), else: out
    # 7^2 = 49 — the final tool used the in-sandbox-generated table correctly
    assert String.trim(out) == "49"
  end

  @tag :build
  @tag timeout: 600_000
  test "a self-contained RUST wc-like tool is compiled in-sandbox (mrustc) and runs sandboxed" do
    # the second-largest reclaim language: a self-contained Rust-2021 CLI (std I/O, no proc-macros/deps) builds
    # via the in-sandbox mrustc->clang->wasm-ld lane (zero native rustc) and runs sandboxed (stdin->stdout).
    src = Path.join(System.tmp_dir!(), "wc_#{System.unique_integer([:positive])}.rs")

    File.write!(src, ~S|
use std::io::Read;
fn main() {
    let mut s = String::new();
    std::io::stdin().read_to_string(&mut s).unwrap();
    let lines = s.lines().count();
    let words = s.split_whitespace().count();
    println!("lines={} words={} bytes={}", lines, words, s.len());
}
|)

    on_exit(fn -> File.rm(src) end)

    case Compilers.rust_compile_to_wasm(src, no_exceptions: true) do
      {:ok, wasm, _} ->
        on_exit(fn -> File.rm(wasm) end)
        out = PackageManager.run(wasm, "one two\nthree four five\n", [])
        out = if is_tuple(out), do: elem(out, 0), else: out
        assert out =~ "lines=2"
        assert out =~ "words=5"

      {:error, reason} ->
        # surface the lane's limit honestly rather than a green-by-skip
        flunk("rust_compile_to_wasm failed for a self-contained CLI: #{inspect(reason) |> String.slice(0, 200)}")
    end
  end
end
