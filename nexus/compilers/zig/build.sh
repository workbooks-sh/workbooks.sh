#!/usr/bin/env bash
# Build the Zig compiler-in-wasm tenant: stage1/zig1.wasm from the pinned zig source
# tarball. zig1.wasm is the bootstrap compiler — it runs the WHOLE zig frontend + Sema
# + C-backend in wasm and emits C, with zero native execution. We do NOT compile it
# (it ships prebuilt in the source tree); we fetch + sha-verify + extract it together
# with lib/ (the std the compiler reads via --zig-lib-dir).
#
# Contract (build_and_register_script): last stdout line = the wasm path; all progress
# goes to stderr.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SD/zig-root"
WASM="$ROOT/stage1/zig1.wasm"
ZV=0.16.0
SHA=43186959edc87d5c7a1be7b7d2a25efffd22ce5807c7af99067f86f99641bfdf
URL="https://ziglang.org/download/$ZV/zig-$ZV.tar.xz"

exec 3>&1 1>&2   # progress → stderr; fd 3 = the one stdout line (the wasm path)

if [ ! -f "$WASM" ]; then
  TARB="$SD/zig-$ZV.tar.xz"
  if [ ! -f "$TARB" ]; then
    echo "[zig] fetching $URL"
    curl -fsSL -o "$TARB" "$URL"
  fi
  echo "[zig] verifying sha256"
  echo "$SHA  $TARB" | shasum -a 256 -c - || { echo "[zig] SHA MISMATCH — refusing"; exit 1; }
  echo "[zig] extracting → $ROOT"
  rm -rf "$ROOT"; mkdir -p "$ROOT"
  tar -xJf "$TARB" -C "$ROOT" --strip-components=1
fi

[ -f "$WASM" ] || { echo "[zig] no zig1.wasm after extract"; exit 1; }
echo "$WASM" 1>&3
