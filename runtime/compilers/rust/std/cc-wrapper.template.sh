#!/bin/sh
# wasm32-wasi-gcc / -g++ wrapper: mrustc invokes `<triple>-gcc` to compile its emitted C.
# Point it at wasi-sdk clang so the trusted libstd cross-compiles to wasm. Install on PATH
# named `wasm32-wasi-gcc` (and `-g++`, `-ar` → llvm-ar) during the libstd prebuild.
exec "$WASI_SDK/bin/clang" --target=wasm32-wasip1 --sysroot="$WASI_SDK/share/wasi-sysroot" \
  -fno-strict-aliasing -w -fwasm-exceptions -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false "$@"
