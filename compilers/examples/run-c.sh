#!/usr/bin/env bash
# Standalone reference: compile + link + run untrusted C ENTIRELY in the wasm sandbox,
# using only wasmtime + the pinned clang toolchain (no Elixir, no native compiler).
#
#   usage: bash examples/run-c.sh path/to/source.c [args-to-the-program...]
#
# This is the minimal embodiment of SPEC.md's "compile-to-wasm" kind: two in-sandbox
# invocations of llvm.core.wasm (clang -c, then wasm-ld), then run the emitted wasm.
set -euo pipefail

SD="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$SD/.." && pwd)"
RT="$(cd "$PKG/.." && pwd)/runtime"
CLANG_DIR="$RT/compilers/clang"
CORE="$CLANG_DIR/clang-root/llvm.core.wasm"
SYSROOT="$CLANG_DIR/clang-root/sysroot"

SRC="${1:?usage: run-c.sh source.c [args...]}"; shift || true
command -v wasmtime >/dev/null || { echo "need wasmtime on PATH"; exit 1; }
[ -f "$CORE" ] || { echo "provisioning clang toolchain..."; bash "$CLANG_DIR/build.sh" >/dev/null; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tmp"
cp "$SRC" "$WORK/src.c"

# wasmtime preopens: sysroot at /usr (clang resource-dir + libc), job at /work, /tmp writable.
RUN() { wasmtime run -W exceptions=y -W memory64=y \
  --dir "$SYSROOT::/usr" --dir "$WORK::/work" --dir "$WORK/tmp::/tmp" --env TMPDIR=/tmp \
  "$CORE" "$@"; }

echo "[1/3] clang -c  (compile in-sandbox)" >&2
RUN clang --target=wasm32-wasip1 --sysroot=/usr -O2 -c /work/src.c -o /work/out.o

echo "[2/3] wasm-ld  (link in-sandbox)" >&2
RUN wasm-ld -m wasm32 -L/usr/lib/wasm32-unknown-wasip1 -L/usr/lib/wasm32-wasip1 \
  /usr/lib/wasm32-wasip1/crt1-command.o /work/out.o -lc \
  /usr/lib/wasm32-unknown-wasip1/libclang_rt.builtins.a -o /work/out.wasm

echo "[3/3] run emitted wasm" >&2
wasmtime run "$WORK/out.wasm" "$@"
