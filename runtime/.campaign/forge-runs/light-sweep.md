# Forge LIGHT sweep — (A) SIMD intrinsics runtime-prove + (B) more C leaf-libs

RAM-sensitive box. SMALL serial compiles only. No mrustc rebuild, no DuckDB-scale.
Experiment in /tmp; report recipes, do NOT commit tracked files.

## TASK A — runtime-prove now-unblocked wasm SIMD intrinsics
mrustc codegen patch (already in place, mrustc_std.wasm rebuilt 15:34) lowers ~30
`llvm.wasm.*` SIMD intrinsics to `__builtin_wasm_*`. Compile a Rust program using
`core::arch::wasm32` intrinsics via `rust_compile_to_wasm(simd: true)`, run via
PackageManager.run, confirm correct result + ops present.

Targets: i8x16_bitmask, i8x16_swizzle, u8x16_narrow (+ a few more).

- [x] DONE — PROVEN. `rust_compile_to_wasm(simd: true)` compiled a program using explicit
      `core::arch::wasm32` intrinsics; ran via PackageManager.run; ALL results correct:
        bitmask=21845 (0x5555)            <- i8x16_bitmask
        swizzle0=25 swizzle1=10           <- i8x16_swizzle
        narrow0=0 narrow2=200 narrow3=255 narrow6=0  <- u8x16_narrow_i16x8 (saturation)
        all_true=true any_true=true i32bitmask=5  <- i32x4_all_true / v128_any_true / i32x4_bitmask
      Op audit (wasm-tools print): i8x16.bitmask=1, i8x16.narrow=1, i32x4.bitmask=1 emitted as
      native v128 ops; swizzle/all_true/any_true folded by clang to equivalent instr sequences
      (count 0 but runtime-correct — intrinsic lowering still functional). Source: /tmp/forge-simd/.
      VERDICT: the patched __builtin_wasm_* lowering runs end-to-end. simd:true (-msimd128 -O2)
      is the required flag (intrinsics need -msimd128).

## TASK B — extend proven C leaf-lib vein
Same shape as md4c: fetch source, build_c_dir, smoke-test through runtime.
Targets: xxHash, cmark, libyaml, miniz. PROVEN (output+recipe) | BLOCKED (reason).

- [x] xxHash 0.8.2 — PROVEN. dir: xxhash.c + xxhash.h + main.c. build_c_dir(dir, [], [], []).
      Canonical vectors EXACT: XXH32("")=02cc5d05, XXH64("")=ef46db3751d8e999. Distinct XXH3_64 too.
- [x] miniz 3.0.2 — PROVEN. dir: miniz.c + miniz.h + main.c (drop examples/). build_c_dir(dir,[],[],[]).
      deflate/inflate roundtrip: orig=76 comp=40 match=1, decompressed bytes identical to source.
- [x] cmark 0.31.1 — PROVEN. dir: 19 lib .c (drop src/main.c CLI) + .h + .inc + driver.c +
      3 generated headers: cmark_version.h (from .in: 0/31/1), cmark_export.h (static stub:
      #define CMARK_EXPORT empty), config.h (HAVE_STDBOOL_H/__builtin_expect/__attribute__,
      CMARK_ATTRIBUTE macro, va_copy fallback). build_c_dir(dir, [], [], []).
      cmark_markdown_to_html → correct: <h1>Hello</h1>, <strong>, <em>, <a href>, <ul><li>.
- [x] libyaml 0.2.5 — PROVEN. dir: 9 src/*.c + yaml_private.h + include/yaml.h + driver.c +
      config.h (YAML_VERSION_* defines). build_c_dir(dir, ["-DHAVE_CONFIG_H=1"], [], []) — the
      -D is REQUIRED (yaml_private.h gates `#include "config.h"` on HAVE_CONFIG_H).
      Parsed YAML doc: scalars=10 maps=2 seqs=1 (all key/value + nested map + seq correct).

## ALL 4 NEW C LEAF-LIBS PROVEN (xxHash, miniz, cmark, libyaml). Task B done.

## RESULTS
(filled in as proven)
