#!/usr/bin/env bash
# Build the in-sandbox JS toolchain (wb-fm0.4): QuickJS-ng compiled to wasm objects via
# clang.wasm + the wb harness (Javy.IO + console + TextEncoder/Decoder). These objects are the
# "libquickjs" the per-program JS lane links against (Workbooks.Compilers.js_compile_to_wasm):
# JS source -> js_src.c (embedded) -> clang.wasm -> wasm-ld(harness + js_src + libquickjs).
# Untrusted JS thus compiles AND runs ENTIRELY in the sandbox (QuickJS interpreter, no JIT, no
# native javy). Idempotent: skips objects that already exist. Last stdout line = the obj dir.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"            # compilers/js
COMPILERS="$(cd "$SD/.." && pwd)"
CLANG="${CLANG:-$COMPILERS/clang/clang-root/llvm.core.wasm}"
CSYS="${CSYS:-$COMPILERS/clang/clang-root/sysroot}"
QJS_REF="${QJS_REF:-v0.10.0}"
QROOT="$SD/qjs-root"; QSRC="$QROOT/quickjs-ng"

exec 3>&1 1>&2
[ -f "$CLANG" ] || { echo "[js] clang.wasm missing — run ../clang/build.sh"; exit 1; }

mkdir -p "$QROOT"
[ -d "$QSRC" ] || { echo "[js] clone quickjs-ng $QJS_REF"; git clone --depth 1 -b "$QJS_REF" https://github.com/quickjs-ng/quickjs "$QSRC"; }

CL(){ wasmtime run -W exceptions=y --dir "$CSYS::/usr" --dir "$1::/work" --dir "$1::/tmp" \
      --env TMPDIR=/tmp "$CLANG" clang --target=wasm32-wasip1 --sysroot=/usr -O2 -w \
      -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS "${@:2}"; }

# QuickJS core objects (the interpreter). xsum = quickjs-ng's extended-precision sum.
for f in quickjs cutils libregexp libunicode xsum; do
  if [ ! -f "$QSRC/$f.o" ]; then echo "[js] clang.wasm $f.c"; CL "$QSRC" -c "/work/$f.c" -o "/work/$f.o"; fi
done

# the wb harness (needs quickjs.h from QSRC). Compiled once; per-program only js_src.c varies.
mkdir -p "$SD/.cc"; cp "$SD/harness.c" "$SD/.cc/harness.c"
if [ ! -f "$SD/harness.o" ] || [ "$SD/harness.c" -nt "$SD/harness.o" ]; then
  echo "[js] clang.wasm harness.c"
  wasmtime run -W exceptions=y --dir "$CSYS::/usr" --dir "$SD/.cc::/work" --dir "$QSRC::/qjs" \
    --dir "$SD/.cc::/tmp" --env TMPDIR=/tmp "$CLANG" clang --target=wasm32-wasip1 --sysroot=/usr \
    -O2 -w -I/qjs -c /work/harness.c -o /work/harness.o
  cp "$SD/.cc/harness.o" "$SD/harness.o"
fi

echo "[js] DONE — libquickjs objects + harness.o in $QSRC + $SD"
echo "$QSRC" 1>&3
