#!/bin/sh
# Emulate native mrustc for minicargo, but route to mrustc.wasm (ABI-consistent .hir) +
# clang.wasm (.c→.o) + native ar (trusted packaging). All untrusted compilation = in wasm.
set -e
D=/tmp/mr/mrustc
SDK=$(cat /tmp/wsdk/sdkpath); SYS=/tmp/yowasp/sysroot; CORE=/tmp/yowasp/pkg/gen/llvm.core.wasm
# find -o output
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
# 1. mrustc.wasm: emit .c + .hir (in-sandbox; cwd preopen so relative paths resolve)
wasmtime run -W exceptions=y --env MRUSTC_TARGET_VER=1.54 --env STD_ENV_ARCH=wasm32 --env TMPDIR=/tmp \
  --dir "$D::." /tmp/mr/mrustc_std.wasm "$@" 1>&2
# 2. clang.wasm: compile emitted .c -> .o, then ar -> rlib
if [ -n "$out" ] && [ -f "$D/$out.c" ]; then
  mkdir -p "$D/.cctmp"
  wasmtime run -W exceptions=y --dir "$SYS::/usr" --dir "$D::/work" --dir "$D/.cctmp::/tmp" --env TMPDIR=/tmp "$CORE" \
    clang --target=wasm32-wasip1 --sysroot=/usr -O1 -fno-strict-aliasing -w -fwasm-exceptions \
      -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false -c "/work/$out.c" -o "/work/$out.o" 1>&2
  "$SDK/bin/llvm-ar" rcs "$D/$out" "$D/$out.o" 2>/dev/null || true
fi
