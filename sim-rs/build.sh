#!/usr/bin/env bash
# Build sim-rs -> app/pkg/ using wasm-pack.
#
# Usage:
#   ./sim-rs/build.sh          # release (opt-level=z, LTO, strip)
#   ./sim-rs/build.sh --dev    # dev build (fast, large, unoptimized)
#
# Output: app/pkg/adbuy_sim.js + app/pkg/adbuy_sim_bg.wasm
# The app imports these as ES modules from ./pkg/adbuy_sim.js.
#
# Requirements: wasm-pack (cargo install wasm-pack), wasm32-unknown-unknown target
#   rustup target add wasm32-unknown-unknown
#   cargo install wasm-pack
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$REPO_ROOT/app/pkg"

if ! command -v wasm-pack &>/dev/null; then
  echo "wasm-pack not found. Install: cargo install wasm-pack" >&2
  exit 1
fi

MODE="${1:-}"
if [[ "$MODE" == "--dev" ]]; then
  echo "Building sim-rs (dev)..."
  wasm-pack build "$SCRIPT_DIR" \
    --target web \
    --out-dir "$OUT_DIR" \
    --out-name adbuy_sim \
    --dev
else
  echo "Building sim-rs (release)..."
  wasm-pack build "$SCRIPT_DIR" \
    --target web \
    --out-dir "$OUT_DIR" \
    --out-name adbuy_sim \
    --release
fi

# wasm-pack emits package.json + .gitignore into pkg/ — remove them
# (we consume the JS/WASM directly, no npm package)
rm -f "$OUT_DIR/package.json" "$OUT_DIR/.gitignore" "$OUT_DIR/adbuy_sim_bg.js"

echo "Built -> $OUT_DIR"
ls -lh "$OUT_DIR"
