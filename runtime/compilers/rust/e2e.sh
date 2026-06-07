#!/usr/bin/env bash
# PROOF: compile + run untrusted Rust ENTIRELY in the wasm sandbox (zero native execution).
# Chain: mrustc.wasm (Rust→C) ×2 [core + user crate] → clang.wasm (C→wasm) → wasm-ld → run.
# Expected output: "RUST IN WASM SANDBOX: 55".
#
# Inputs (all wasm, all run under wasmtime — nothing native compiles the untrusted source):
#   MRUSTC  = mrustc.wasm           (build.sh)
#   CLANG   = llvm.core.wasm        (../clang/build.sh)  + its sysroot
#   RUSTSRC = rustc-1.54.0-src      (for library/core; pinned)
# Usage: MRUSTC=… CLANG=… CSYS=… RUSTSRC=… bash e2e.sh
set -euo pipefail
MRUSTC="${MRUSTC:?path to mrustc.wasm}"
CLANG="${CLANG:?path to llvm.core.wasm}"
CSYS="${CSYS:?path to clang wasi sysroot (has /usr layout: include,lib)}"
RUSTSRC="${RUSTSRC:?path to rustc-1.54.0-src}"
W="$(mktemp -d)"; mkdir -p "$W/out" "$W/c/tmp" "$W/tmp"; trap 'rm -rf "$W"' EXIT
TGT=arm-linux-gnu          # 32-bit + i64-align-8: matches wasm32 layout
MR(){ wasmtime run -W exceptions=y --env MRUSTC_TARGET_VER=1.54 --env TMPDIR=/tmp \
      --dir "$1::/work" --dir "$W/out::/out" --dir "$W/tmp::/tmp" "$MRUSTC" "${@:2}"; }
CL(){ wasmtime run -W exceptions=y --dir "$CSYS::/usr" --dir "$W/c::/work" --dir "$W/c/tmp::/tmp" \
      --env TMPDIR=/tmp "$CLANG" "$@"; }

# the untrusted user program (no_std; exports a C-callable fn)
cat > "$W/prog.rs" <<'RS'
#![no_std]
#[panic_handler] fn ph(_: &core::panic::PanicInfo) -> ! { loop {} }
fn fib(n: u32) -> u32 { if n < 2 { n } else { fib(n-1) + fib(n-2) } }
#[no_mangle] pub extern "C" fn rust_compute() -> u32 { fib(10) }
RS
cat > "$W/c/harness.c" <<'C'
#include <stdio.h>
extern unsigned rust_compute(void);
int main(void){ printf("RUST IN WASM SANDBOX: %u\n", rust_compute()); return 0; }
C

echo "[1/6] mrustc.wasm: libcore -> C (in sandbox)" >&2
MR "$RUSTSRC" /work/library/core/src/lib.rs --crate-name core --crate-type lib \
   --out-dir /out --target "$TGT" --edition 2018 >&2
echo "[2/6] mrustc.wasm: prog.rs -> C (in sandbox)" >&2
MR "$W" /work/prog.rs --crate-name prog --crate-type lib -L /out --out-dir /out \
   --target "$TGT" --edition 2018 >&2

cp "$W/out/libcore.rlib.c" "$W/c/core.c"; cp "$W/out/libprog.rlib.c" "$W/c/prog.c"
# mrustc emits ARM memory-barrier inline asm for the arm target; no-op it for single-threaded
# wasm (a proper wasm32 mrustc target spec would emit none — see PORT-LOG).
sed -i.bak 's/__asm__ __volatile__(.*);/\/* asm stubbed for wasm *\/;/' "$W/c/core.c" && rm -f "$W/c/core.c.bak"

CF="--target=wasm32-wasip1 --sysroot=/usr -O1 -fno-strict-aliasing -w -fwasm-exceptions -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false"
echo "[3/6] clang.wasm: core.c -> core.o (in sandbox)" >&2; CL clang ${=CF} -c /work/core.c -o /work/core.o >&2
echo "[4/6] clang.wasm: prog.c -> prog.o (in sandbox)" >&2; CL clang ${=CF} -c /work/prog.c -o /work/prog.o >&2
CL clang --target=wasm32-wasip1 --sysroot=/usr -O1 -w -c /work/harness.c -o /work/harness.o >&2
echo "[5/6] wasm-ld: link -> prog.wasm (in sandbox)" >&2
CL wasm-ld -m wasm32 -L/usr/lib/wasm32-unknown-wasip1 -L/usr/lib/wasm32-wasip1 \
   /usr/lib/wasm32-wasip1/crt1-command.o /work/harness.o /work/prog.o /work/core.o \
   -lc /usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a -o /work/prog.wasm >&2
echo "[6/6] run the emitted wasm:" >&2
wasmtime run -W exceptions=y "$W/c/prog.wasm"
