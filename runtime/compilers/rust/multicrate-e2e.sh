#!/usr/bin/env bash
# PROOF (wb-3s8 / wb-2pt): a user Rust crate + an EXTERNAL dependency crate compile and run
# ENTIRELY in the wasm sandbox — the foundation for crates.io dependency support. The dep is
# compiled by mrustc.wasm -> C -> clang.wasm -> .o+.hir (the same path as libstd's 16 deps),
# then the user crate compiles with `--extern dep` and links against it. Expected output:
#   "MULTICRATE: 42 (hello, dep!)"
# Prereq: the libstd prebuild (provision-rust.sh / std/prebuild-libstd.sh).
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; COMPILERS="$(cd "$SD/.." && pwd)"
MRDIR="$SD/mrustc-root/mrustc"
MRWASM="${MRWASM:-$SD/mrustc-root/mrustc_std.wasm}"
CLANG="${CLANG:-$COMPILERS/clang/clang-root/llvm.core.wasm}"
CSYS="${CSYS:-$COMPILERS/clang/clang-root/sysroot}"
WASI_SDK="${WASI_SDK:-$SD/mrustc-root/wasi-sdk-33.0-arm64-macos}"
O="output-wasi"
[ -f "$MRDIR/$O/libstd.rlib.o" ] || { echo "[multicrate] libstd not prebuilt — run provision-rust.sh"; exit 1; }

cd "$MRDIR"; mkdir -p poc .mrtmp .cctmp
trap 'rm -f "$O"/pocmain.* "$O"/libmylib.* poc/*.rs 2>/dev/null; rmdir poc 2>/dev/null || true' EXIT

cat > poc/mylib.rs <<'RS'
pub fn triple(x: i32) -> i32 { x * 3 }
pub fn greet(name: &str) -> String { format!("hello, {}!", name) }
RS
cat > poc/main.rs <<'RS'
fn main() { println!("MULTICRATE: {} ({})", mylib::triple(14), mylib::greet("dep")); }
RS

MR(){ wasmtime run -W exceptions=y -W max-wasm-stack=134217728 \
      --env MRUSTC_TARGET_VER=1.54 --env STD_ENV_ARCH=wasm32 --env TMPDIR=/tmp \
      --dir "$MRDIR::." --dir "$MRDIR/.mrtmp::/tmp" "$MRWASM" "$@"; }
CL(){ wasmtime run -W exceptions=y --dir "$CSYS::/usr" --dir "$MRDIR::/work" --dir "$MRDIR/.cctmp::/tmp" \
      --env TMPDIR=/tmp "$CLANG" "$@"; }
CLANG_FLAGS="--target=wasm32-wasip1 --sysroot=/usr -O1 -fno-strict-aliasing -w -fwasm-exceptions -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false -Xclang -disable-llvm-verifier"

echo "[multicrate] 1/5 mrustc.wasm: dep crate mylib -> C" >&2
MR poc/mylib.rs --crate-name mylib --crate-type rlib -o "$O/libmylib.rlib" -L "$O" --out-dir "$O" --target wasm32-wasi --edition 2018 >&2
echo "[multicrate] 2/5 clang.wasm: mylib.c -> .o (+ ar)" >&2
# shellcheck disable=SC2086
CL clang $CLANG_FLAGS -c "/work/$O/libmylib.rlib.c" -o "/work/$O/libmylib.rlib.o" >&2
"$WASI_SDK/bin/llvm-ar" rcs "$O/libmylib.rlib" "$O/libmylib.rlib.o" 2>/dev/null || true
echo "[multicrate] 3/5 mrustc.wasm: user crate main.rs --extern mylib -> C" >&2
MR poc/main.rs --crate-name pocmain --crate-type bin --extern mylib="$O/libmylib.rlib" -L "$O" --out-dir "$O" --target wasm32-wasi --edition 2018 >&2
echo "[multicrate] 4/5 clang.wasm: pocmain.c -> .o" >&2
# shellcheck disable=SC2086
CL clang $CLANG_FLAGS -c "/work/$O/pocmain.c" -o "/work/$O/pocmain.o" >&2
echo "[multicrate] 5/5 wasm-ld: link user + dep + libstd + shim + ustub" >&2
LIBSTD_OBJS=$(ls "$O"/*.rlib.o | grep -v 'pocmain\|libmylib' | sed 's#^#/work/#' | tr '\n' ' ')
# shellcheck disable=SC2086
CL wasm-ld -m wasm32 -L/usr/lib/wasm32-unknown-wasip1 -L/usr/lib/wasm32-wasip1 \
  /usr/lib/wasm32-wasip1/crt1-command.o "/work/$O/pocmain.o" "/work/$O/libmylib.rlib.o" $LIBSTD_OBJS \
  "/work/$O/wasi_shim.o" "/work/$O/ustub.o" \
  -lc -lsetjmp /usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a -o "/work/$O/pocmain.wasm" >&2
echo "[multicrate] run:" >&2
wasmtime run -W exceptions=y "$O/pocmain.wasm"
