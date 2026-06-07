#!/usr/bin/env bash
# Run all sim checks: build WASM then run Rust tests (including the size guard).
# Usage: bash sim-rs/check.sh  (from projects/adbuy/ root)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "[sim-check] building WASM..."
bash build.sh

echo "[sim-check] running cargo tests..."
cargo test

echo "[sim-check] all ok."
