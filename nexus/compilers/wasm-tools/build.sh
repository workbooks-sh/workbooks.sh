#!/usr/bin/env bash
# Build wasm-tools to wasm32-wasip1 so component adapt/validate run IN the sandbox (wb-fm0.8) —
# the native Go-style trusted provisioning (native cargo builds the trusted tool; it never
# compiles untrusted source). Idempotent. Output: build/tools/wasm-tools.wasm.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
OUT="$SD/../../build/tools/wasm-tools.wasm"
VER="${WASM_TOOLS_VER:-1.0.60}"
exec 3>&1 1>&2
[ -f "$OUT" ] && { echo "[wasm-tools] present — skip"; echo "$OUT" 1>&3; exit 0; }
command -v cargo >/dev/null || { echo "[wasm-tools] native cargo required"; exit 1; }
rustup target add wasm32-wasip1 >/dev/null 2>&1 || true
tmp="$(mktemp -d)"
echo "[wasm-tools] cargo install wasm-tools@$VER --target wasm32-wasip1"
cargo install wasm-tools --version "$VER" --target wasm32-wasip1 --root "$tmp" --no-track >&2
mkdir -p "$(dirname "$OUT")"; cp "$tmp/bin/wasm-tools.wasm" "$OUT"; rm -rf "$tmp"
echo "[wasm-tools] DONE — $OUT"; echo "$OUT" 1>&3
