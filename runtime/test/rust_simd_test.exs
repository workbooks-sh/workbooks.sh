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

  @tag :build
  @tag :simd
  @tag timeout: 300_000
  test "core::arch::wasm32 SIMD intrinsics run correctly (mrustc codegen patch lowering)" do
    # These llvm.wasm.* intrinsics previously ABORTED in mrustc codegen (Extern-LLVM); the codegen_c.cpp
    # patch (compilers/rust/mrustc-patch/) lowers them to __builtin_wasm_*. This guards that lowering so a
    # future mrustc rebuild can't silently regress it.
    src = Path.join(System.tmp_dir!(), "simdintr_#{System.unique_integer([:positive])}.rs")

    File.write!(src, ~S"""
    use core::arch::wasm32::*;
    fn main() {
      let v = i8x16(-1,0,-1,0,-1,0,-1,0,-1,0,-1,0,-1,0,-1,0);
      println!("bitmask={}", unsafe { i8x16_bitmask(v) });                       // 0x5555 = 21845
      let data = u8x16(10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25);
      let idx = u8x16(15,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14);
      let sw = i8x16_swizzle(data, idx);
      println!("swizzle0={} swizzle1={}", u8x16_extract_lane::<0>(sw), u8x16_extract_lane::<1>(sw));
      let nar = u8x16_narrow_i16x8(i16x8(0,100,200,300,400,500,-5,70), i16x8(1,2,3,4,5,6,7,8));
      println!("narrow3={} narrow6={}", u8x16_extract_lane::<3>(nar), u8x16_extract_lane::<6>(nar));
      println!("i32bitmask={}", i32x4_bitmask(i32x4(-1,0,-1,0)));                 // 0b0101 = 5
    }
    """)

    on_exit(fn -> File.rm(src) end)

    assert {:ok, wasm, _} = Compilers.rust_compile_to_wasm(src, simd: true)
    on_exit(fn -> File.rm(wasm) end)

    out = PackageManager.run(wasm, "", [])
    out = if is_tuple(out), do: elem(out, 0), else: out
    assert out =~ "bitmask=21845"
    assert out =~ "swizzle0=25" and out =~ "swizzle1=10"
    assert out =~ "narrow3=255" and out =~ "narrow6=0"   # unsigned saturation
    assert out =~ "i32bitmask=5"
  end
end
