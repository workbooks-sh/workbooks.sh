#!/bin/sh
# wasm32-wasi-gcc: cross-compile mrustc's C for wasm via wasi-sdk clang.
# Fix-ups in the emitted .c: stub ARM barrier asm + force __int128 align 8 (Rust ABI;
# clang's native __int128 is align 16 → mismatches mrustc's layout asserts).
args=""
for a in "$@"; do
  case "$a" in
    *.c)
      cp "$a" "$a.stub.c" 2>/dev/null
      sed -i.bak -e 's/__asm__ __volatile__(.*);/\/* asm stubbed *\/;/'         -e 's/typedef unsigned __int128 uint128_t;/typedef unsigned __int128 __attribute__((aligned(8))) uint128_t;/'         -e 's/typedef signed __int128 int128_t;/typedef signed __int128 __attribute__((aligned(8))) int128_t;/'         "$a.stub.c" 2>/dev/null && rm -f "$a.stub.c.bak"
      args="$args $a.stub.c" ;;
    *) args="$args $a" ;;
  esac
done
exec "/tmp/wsdk/wasi-sdk-33.0-arm64-macos/bin/clang" --target=wasm32-wasip1 --sysroot="/tmp/wsdk/wasi-sdk-33.0-arm64-macos/share/wasi-sysroot" -fno-strict-aliasing -w -fwasm-exceptions -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false $args
