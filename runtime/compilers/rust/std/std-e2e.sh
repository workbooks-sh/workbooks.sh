#!/usr/bin/env bash
# PROVEN: untrusted Rust + full std compiles AND runs ENTIRELY in the wasm sandbox.
# Output: "UNTRUSTED RUST+STD, COMPILED IN-SANDBOX: sum(1..=10) = 55"
# Prereqs (env): MRUSTC_WASM (mrustc.wasm, build.sh), CLANG_CORE (llvm.core.wasm) + CSYS
# (its sysroot), WASI_SDK, RUSTSRC (rustc-1.54.0-src), MR (a writable mrustc work dir with
# native mrustc+minicargo for the trusted libstd prebuild).
# ── ONE-TIME trusted libstd prebuild (by mrustc.wasm, hash-consistent __2) ──
#  1. bin/mrustc := wrapper that runs MRUSTC_WASM (emit .c+.hir) + clang.wasm (.c->.o) + ar.
#  2. minicargo LIBS  → 14 dep crates (.hir __2 + .o).
#  3. wasi crate + libstd via the wrapper (minicargo skips the wasi target-dep).
#  4. clang.wasm libstd.c -> libstd.o  WITH  -Xclang -disable-llvm-verifier
#     (clang's verifier spuriously rejects 'signext on incompatible type' in the synthesized
#      abort_bitcast fn; signext is a no-op on wasm, so the .o is correct).
# ── PER untrusted program (fully in-sandbox) ──
#  5. mrustc.wasm  user.rs -> user.c           (against the __2 libstd.hir)  [zero native exec]
#  6. clang.wasm   user.c  -> user.o                                         [zero native exec]
#  7. wasm-ld  crt1-command.o user.o <libstd .o> wasi_shim.o ustub.o -lsetjmp -o user.wasm
#     (ustub.o = `void _Unwind_Resume(void*){__builtin_trap();}`; sjlj EH != Rust unwind)
#  8. wasmtime run user.wasm
# Full command transcript + the exact flags: ../PORT-LOG.org iters 13-24.
echo "see PORT-LOG.org iter 24 for the validated command sequence; this file documents the recipe."
