#!/usr/bin/env bash
# RUNNABLE PROOF (wb-fm0.3): untrusted Rust + full std compiles AND runs ENTIRELY in the wasm
# sandbox. Expected output: "UNTRUSTED RUST+STD, COMPILED IN-SANDBOX: sum(1..=10) = 55".
#
# Per-program chain (zero native execution for the untrusted .rs):
#   1. mrustc.wasm  user.rs -> user.c          (against the prebuilt __2 libstd; in-sandbox)
#   2. clang.wasm   user.c  -> user.o          (-Xclang -disable-llvm-verifier; in-sandbox)
#   3. wasm-ld  crt1-command.o user.o <libstd .o> wasi_shim.o ustub.o -lc -lsetjmp builtins
#        - wasi_shim.o: bridges the wasi crate's bare imports (fd_write…) -> wasi-libc __wasi_*
#          (else runtime "unknown import: env::fd_write"). ustub.o: _Unwind_Resume trap stub.
#   4. wasmtime run user.wasm
# Prereq: the libstd prebuild (std/prebuild-libstd.sh). Run ../provision-rust.sh first if absent.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; RUST="$(cd "$SD/.." && pwd)"; COMPILERS="$(cd "$RUST/.." && pwd)"
MRDIR="$RUST/mrustc-root/mrustc"
MRWASM="${MRWASM:-$RUST/mrustc-root/mrustc_std.wasm}"
CLANG="${CLANG:-$COMPILERS/clang/clang-root/llvm.core.wasm}"
CSYS="${CSYS:-$COMPILERS/clang/clang-root/sysroot}"
O="output-wasi-174"

[ -f "$MRDIR/$O/libstd.rlib.o" ] || { echo "[std-e2e] libstd not prebuilt — run ../provision-rust.sh"; exit 1; }
cd "$MRDIR"; mkdir -p .mrtmp .cctmp
MR(){ wasmtime run -W exceptions=y -W max-wasm-stack=536870912 \
      --env MRUSTC_TARGET_VER=1.74 --env STD_ENV_ARCH=wasm32 --env TMPDIR=/tmp \
      --dir "$MRDIR::." --dir "$MRDIR/.mrtmp::/tmp" "$MRWASM" "$@"; }
CL(){ wasmtime run -W exceptions=y --dir "$CSYS::/usr" --dir "$MRDIR::/work" --dir "$MRDIR/.cctmp::/tmp" \
      --env TMPDIR=/tmp "$CLANG" "$@"; }

cat > "$O/e2e.rs" <<'RS'
fn main() {
    let v: Vec<u32> = (1..=10).collect();
    let s: u32 = v.iter().sum();
    println!("UNTRUSTED RUST+STD, COMPILED IN-SANDBOX: sum(1..=10) = {}", s);
}
RS

echo "[std-e2e] 1/4 mrustc.wasm e2e.rs -> C" >&2
MR "$O/e2e.rs" --crate-name e2e --crate-type bin -L "$O" --out-dir "$O" --target wasm32-wasi --edition 2021 >&2
echo "[std-e2e] 2/4 clang.wasm e2e.c -> .o" >&2
CL clang --target=wasm32-wasip1 --sysroot=/usr -O1 -fno-strict-aliasing -w -fwasm-exceptions \
  -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false -Xclang -disable-llvm-verifier \
  -c "/work/$O/e2e.c" -o "/work/$O/e2e.o" >&2
# shim + unwind stub (cache once)
[ -f "$O/wasi_shim.o" ] || { cp "$COMPILERS/zig/wasi_shim.c" "$O/wasi_shim.c"; CL clang --target=wasm32-wasip1 --sysroot=/usr -O1 -w -c "/work/$O/wasi_shim.c" -o "/work/$O/wasi_shim.o" >&2; }
[ -f "$O/ustub.o" ]     || { cp "$SD/ustub.c" "$O/ustub.c";            CL clang --target=wasm32-wasip1 --sysroot=/usr -O1 -w -c "/work/$O/ustub.c"     -o "/work/$O/ustub.o" >&2; }
echo "[std-e2e] 3/4 wasm-ld link" >&2
LIBSTD_OBJS=$(ls "$O"/*.rlib.o | sed 's#^#/work/#' | tr '\n' ' ')
# shellcheck disable=SC2086
CL wasm-ld -m wasm32 -L/usr/lib/wasm32-unknown-wasip1 -L/usr/lib/wasm32-wasip1 \
  /usr/lib/wasm32-wasip1/crt1-command.o "/work/$O/e2e.o" $LIBSTD_OBJS \
  "/work/$O/wasi_shim.o" "/work/$O/ustub.o" \
  -lc -lsetjmp /usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a -o "/work/$O/e2e.wasm" >&2
echo "[std-e2e] 4/4 run:" >&2
wasmtime run -W exceptions=y "$O/e2e.wasm"
