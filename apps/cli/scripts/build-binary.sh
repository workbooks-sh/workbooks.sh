#!/usr/bin/env bash
# Build self-contained brandnana binaries via `bun build --compile`.
#
# Produces one static executable per (os, arch) — no Node or Bun required at
# runtime. SQLite is bundled via bun:sqlite (the native addon shim in
# src/sqlite.ts). keytar falls back to ~/.config/brandnana/credentials.json
# automatically when the OS keychain is unavailable (already implemented in
# src/keychain.ts).
#
# Usage:
#   ./scripts/build-binary.sh                 # all 4 targets
#   ./scripts/build-binary.sh darwin-arm64    # single target
#
# Requires Bun >= 1.1.0 (--compile flag + bun:sqlite).

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTDIR="$CLI_DIR/dist"
ENTRY="$CLI_DIR/src/index.ts"

mkdir -p "$OUTDIR"

# Map platform slug → bun --target value
bun_target_for() {
  case "$1" in
    darwin-arm64) echo "bun-darwin-arm64" ;;
    darwin-x64)   echo "bun-darwin-x64" ;;
    linux-x64)    echo "bun-linux-x64" ;;
    linux-arm64)  echo "bun-linux-arm64" ;;
    *) echo "" ;;
  esac
}

ALL_TARGETS="darwin-arm64 darwin-x64 linux-x64 linux-arm64"

# If a specific target is requested, build only that one.
if [[ $# -gt 0 ]]; then
  requested="$1"
  bun_target="$(bun_target_for "$requested")"
  if [[ -z "$bun_target" ]]; then
    echo "Unknown target: $requested" >&2
    echo "Valid targets: $ALL_TARGETS" >&2
    exit 1
  fi
  BUILD_TARGETS="$requested"
else
  BUILD_TARGETS="$ALL_TARGETS"
fi

echo "Building brandnana binaries…"
echo ""

for platform in $BUILD_TARGETS; do
  bun_target="$(bun_target_for "$platform")"
  outfile="$OUTDIR/brandnana-$platform"

  printf "  %-20s → %s\n" "$platform" "$outfile"
  # Externalize the native/optional deps (same set the `build` npm script
  # externalizes): better-sqlite3 is unused (the CLI uses bun:sqlite), keytar is
  # dynamically imported with a ~/.config JSON fallback, and bindings is keytar's
  # dep. Without these, `--compile` tries to bundle keytar's lib, which statically
  # requires keytar.node — absent under `bun install --ignore-scripts` — so the
  # compile fails to resolve it.
  bun build --compile \
    --target="$bun_target" \
    "$ENTRY" \
    --external keytar \
    --external better-sqlite3 \
    --external bindings \
    --outfile="$outfile" 2>&1 | sed 's/^/    /'

  size=$(du -sh "$outfile" | cut -f1)
  echo "    size: $size"
  echo ""
done

echo "Done."
