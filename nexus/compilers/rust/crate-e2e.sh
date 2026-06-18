#!/usr/bin/env bash
# PROOF (wb-3s8): a REAL crates.io crate compiles + runs ENTIRELY in the wasm sandbox.
# Fetches fnv 1.0.7 from the static CDN, compiles it (WITH its `std` feature — fnv gates
# FnvHashMap behind cfg(feature="std")), then builds + runs a user program that uses it.
# Expected: "REAL-CRATE fnv: the=3 cat=2 entries=5".
#
# Demonstrates the crates.io pipeline pieces proven so far (wb-3s8):
#   fetch (static.crates.io) -> features (--cfg feature="std") -> dep compile (mrustc.wasm) ->
#   user compile (--extern) -> link -> run. Pure-Rust, no proc-macros, no build.rs, ~1.54-OK.
# Prereq: libstd prebuild (provision-rust.sh). Network needed for the fetch.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; COMPILERS="$(cd "$SD/.." && pwd)"
MRDIR="$SD/mrustc-root/mrustc"
MRWASM="${MRWASM:-$SD/mrustc-root/mrustc_std.wasm}"
CLANG="${CLANG:-$COMPILERS/clang/clang-root/llvm.core.wasm}"
CSYS="${CSYS:-$COMPILERS/clang/clang-root/sysroot}"
WASI_SDK="${WASI_SDK:-$SD/mrustc-root/wasi-sdk-33.0-arm64-macos}"
O="output-wasi"
CRATE=fnv; VER=1.0.7; FEATURES='feature="std"'
[ -f "$MRDIR/$O/libstd.rlib.o" ] || { echo "[crate] libstd not prebuilt — run provision-rust.sh"; exit 1; }

cd "$MRDIR"; mkdir -p poc .mrtmp .cctmp
trap 'rm -f "$O"/cm.* "$O"/lib$CRATE.* poc/*.rs 2>/dev/null; rmdir poc 2>/dev/null || true' EXIT

# 1. fetch + extract the crate (download, not compile)
tb="poc/$CRATE-$VER.crate"
[ -f "$tb" ] || curl -fsSL "https://static.crates.io/crates/$CRATE/$CRATE-$VER.crate" -o "$tb"
tar -xzf "$tb" -C poc
cp "poc/$CRATE-$VER/lib.rs" "poc/$CRATE.rs"
cat > poc/main.rs <<RS
use $CRATE::FnvHashMap;
fn main() {
    let mut m: FnvHashMap<&str, i32> = FnvHashMap::default();
    for w in "the cat sat on the mat the cat".split_whitespace() { *m.entry(w).or_insert(0) += 1; }
    println!("REAL-CRATE $CRATE: the={} cat={} entries={}", m["the"], m["cat"], m.len());
}
RS

MR(){ wasmtime run -W exceptions=y -W max-wasm-stack=134217728 --env MRUSTC_TARGET_VER=1.54 --env STD_ENV_ARCH=wasm32 --env TMPDIR=/tmp --dir "$MRDIR::." --dir "$MRDIR/.mrtmp::/tmp" "$MRWASM" "$@"; }
CL(){ wasmtime run -W exceptions=y --dir "$CSYS::/usr" --dir "$MRDIR::/work" --dir "$MRDIR/.cctmp::/tmp" --env TMPDIR=/tmp "$CLANG" "$@"; }
FL="--target=wasm32-wasip1 --sysroot=/usr -O1 -fno-strict-aliasing -w -fwasm-exceptions -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false -Xclang -disable-llvm-verifier"

echo "[crate] compile dep $CRATE $VER (with $FEATURES)" >&2
MR "poc/$CRATE.rs" --crate-name "$CRATE" --crate-type rlib -o "$O/lib$CRATE.rlib" -L "$O" --out-dir "$O" --target wasm32-wasi --edition 2018 --cfg "$FEATURES" >&2
# shellcheck disable=SC2086
CL clang $FL -c "/work/$O/lib$CRATE.rlib.c" -o "/work/$O/lib$CRATE.rlib.o" >&2
"$WASI_SDK/bin/llvm-ar" rcs "$O/lib$CRATE.rlib" "$O/lib$CRATE.rlib.o" 2>/dev/null || true
echo "[crate] compile user program (--extern $CRATE)" >&2
MR poc/main.rs --crate-name cm --crate-type bin --extern "$CRATE=$O/lib$CRATE.rlib" -L "$O" --out-dir "$O" --target wasm32-wasi --edition 2018 >&2
# shellcheck disable=SC2086
CL clang $FL -c "/work/$O/cm.c" -o "/work/$O/cm.o" >&2
echo "[crate] link + run" >&2
LIBSTD=$(ls "$O"/*.rlib.o | grep -vE "cm\.|lib$CRATE" | sed 's#^#/work/#' | tr '\n' ' ')
# shellcheck disable=SC2086
CL wasm-ld -m wasm32 -L/usr/lib/wasm32-unknown-wasip1 -L/usr/lib/wasm32-wasip1 /usr/lib/wasm32-wasip1/crt1-command.o "/work/$O/cm.o" "/work/$O/lib$CRATE.rlib.o" $LIBSTD "/work/$O/wasi_shim.o" "/work/$O/ustub.o" -lc -lsetjmp /usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a -o "/work/$O/cm.wasm" >&2
wasmtime run -W exceptions=y "$O/cm.wasm"
