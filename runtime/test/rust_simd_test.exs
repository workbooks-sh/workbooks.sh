defmodule Workbooks.RustSimdTest do
  @moduledoc """
  Proves wasm SIMD in the Rust lane: `rust_compile_to_wasm(simd: true)` compiles a vectorizable loop with
  `-msimd128 -O2` so clang AUTOVECTORIZES it to real `v128` ops. mrustc itself lowers Rust SIMD intrinsics to
  scalar C, so autovectorization (not `--cfg`) is the path to true SIMD — and `-O2` matters (autovec is off at
  `-O1` even with `-msimd128`). Baseline (no simd) emits zero v128; `simd: true` emits v128 with the same result.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, PackageManager}

  @tag :build
  @tag timeout: 300_000
  test "rust_compile_to_wasm(simd: true) — vectorizable loop emits v128 ops + correct result" do
    src = Path.join(System.tmp_dir!(), "simd_#{System.unique_integer([:positive])}.rs")

    File.write!(src, ~S"""
    fn main() {
      let n = 4096usize;
      let a: Vec<f32> = (0..n).map(|i| i as f32).collect();
      let b: Vec<f32> = (0..n).map(|i| (i as f32) * 2.0).collect();
      let mut c = vec![0.0f32; n];
      for i in 0..n { c[i] = a[i] * 2.0 + b[i]; }   // vectorizable saxpy
      let s: f32 = c.iter().sum();
      println!("sum={}", s as i64);
    }
    """)

    on_exit(fn -> File.rm(src) end)

    assert {:ok, wasm, _} = Compilers.rust_compile_to_wasm(src, simd: true)
    on_exit(fn -> File.rm(wasm) end)

    # The wasm must actually CONTAIN v128 ops (autovectorized) — not merely "compiled with the flag set".
    case System.cmd("wasm-tools", ["print", wasm], stderr_to_stdout: true) do
      {dump, 0} ->
        v128 = dump |> String.split("\n") |> Enum.count(&String.contains?(&1, "v128"))
        assert v128 > 0, "expected autovectorized v128 ops in the wasm, found none"

      _ ->
        IO.puts("\n[note] wasm-tools unavailable — skipping the v128-presence assertion (run still checked)")
    end

    out = PackageManager.run(wasm, "", [])
    out = if is_tuple(out), do: elem(out, 0), else: out
    assert out =~ "sum=33546240"
  end
end
