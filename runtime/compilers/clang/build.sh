#!/usr/bin/env bash
# Provision the clang/lld compiler-in-wasm: YoWASP's LLVM built FOR wasm32-wasi (runs on
# wasmtime). We do NOT build LLVM — we fetch + sha-verify the prebuilt npm package and
# extract llvm.core.wasm (the clang+lld multitool) + its sysroot (libc/headers/builtins).
#
# This is the ONLY mature full-C→wasm compiler that runs in the sandbox (tcc/chibicc/c4
# emit native or interpret a subset — they cannot emit wasm). It is the production C lane
# and the backend that finishes Zig (.zig→C via zig1.wasm, then C→wasm here).
#
# Contract (build_and_register_script): last stdout line = the wasm path; progress → stderr.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SD/clang-root"
CORE="$ROOT/llvm.core.wasm"
VERSION="22.0.0-git20542-10"
SHA=6230ea1afa9691fa065935cf68c01642ff9b31c183fe8ac64cdfda025df06009
URL="https://registry.npmjs.org/@yowasp/clang/-/clang-${VERSION}.tgz"

exec 3>&1 1>&2   # progress → stderr; fd 3 = the one stdout line (the wasm path)

if [ ! -f "$CORE" ]; then
  TARB="$SD/clang-${VERSION}.tgz"
  if [ ! -f "$TARB" ]; then
    echo "[clang] fetching $URL"
    curl -fsSL -o "$TARB" "$URL"
  fi
  echo "[clang] verifying sha256"
  echo "$SHA  $TARB" | shasum -a 256 -c - || { echo "[clang] SHA MISMATCH — refusing"; exit 1; }
  echo "[clang] extracting → $ROOT"
  rm -rf "$ROOT"; mkdir -p "$ROOT/sysroot"
  tar -xzf "$TARB" -C "$ROOT" --strip-components=2 package/gen/llvm.core.wasm package/gen/llvm-resources.tar
  # The sysroot (include/ lib/ share/) mounts at the clang resource-dir /usr at run time.
  tar -xf "$ROOT/llvm-resources.tar" -C "$ROOT/sysroot"
  rm -f "$ROOT/llvm-resources.tar"
fi

# wb: wasm32-wasi-threads OVERLAY (shared-memory pthreads). The yowasp package ships only wasm32-wasip1, so we
# overlay the threads libc/crt/headers from the wasi-sdk sysroot package — enabling Compilers.compile_threads.
# Additive + idempotent (skips if already present), so it lands on fresh AND already-provisioned roots.
THR_URL="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-25/wasi-sysroot-25.0.tar.gz"
THR_SHA="d09c62c18efcddffe4b2fdd8c5830109cc8e36130cdbc9acdc0bd1b204c942bb"
if [ -d "$ROOT/sysroot/lib" ] && [ ! -d "$ROOT/sysroot/lib/wasm32-wasi-threads" ]; then
  TTH="$SD/wasi-sysroot-25.0.tar.gz"
  if [ ! -f "$TTH" ]; then echo "[clang] fetching wasm32-wasi-threads sysroot"; curl -fsSL -o "$TTH" "$THR_URL"; fi
  echo "$THR_SHA  $TTH" | shasum -a 256 -c - || { echo "[clang] threads sysroot SHA MISMATCH — refusing"; exit 1; }
  echo "[clang] overlaying wasm32-wasi-threads sysroot"
  THRTMP="$SD/.thr-tmp"; rm -rf "$THRTMP"; mkdir -p "$THRTMP"
  tar -xzf "$TTH" -C "$THRTMP"
  cp -R "$THRTMP/wasi-sysroot-25.0/lib/wasm32-wasi-threads" "$ROOT/sysroot/lib/"
  cp -R "$THRTMP/wasi-sysroot-25.0/include/wasm32-wasi-threads" "$ROOT/sysroot/include/"
  rm -rf "$THRTMP"
fi

[ -f "$CORE" ] || { echo "[clang] no llvm.core.wasm after extract"; exit 1; }
[ -d "$ROOT/sysroot/lib" ] || { echo "[clang] no sysroot after extract"; exit 1; }
echo "$CORE" 1>&3
