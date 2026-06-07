#!/usr/bin/env bash
# Brandnana CLI installer.
#
# Resolution strategy:
#   1. If $BRANDNANA_REPO is set, use it.
#   2. If we're already inside the monorepo (apps/cli exists relative to
#      this script), use that checkout.
#   3. Otherwise clone the public repo into $HOME/.brandnana/src and use that.
#
# Then: bun install + bun run build + symlink the bin into ~/.local/bin
# (or /usr/local/bin if writable).
set -euo pipefail

REPO_URL="https://github.com/shinyobjectz/brandnana.git"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v bun >/dev/null 2>&1; then
  echo "error: bun is required (https://bun.sh). Install bun and re-run." >&2
  exit 1
fi

ROOT=""
if [[ -n "${BRANDNANA_REPO:-}" && -d "$BRANDNANA_REPO/apps/cli" ]]; then
  ROOT="$BRANDNANA_REPO"
elif [[ -d "$SCRIPT_DIR/../../../apps/cli" ]]; then
  ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
else
  ROOT="$HOME/.brandnana/src"
  if [[ -d "$ROOT/.git" ]]; then
    echo "==> updating existing checkout at $ROOT"
    git -C "$ROOT" pull --ff-only
  else
    mkdir -p "$(dirname "$ROOT")"
    echo "==> cloning $REPO_URL into $ROOT"
    git clone --depth 1 "$REPO_URL" "$ROOT"
  fi
fi

echo "==> installing dependencies in $ROOT"
(cd "$ROOT" && bun install)

echo "==> building @brandnana/cli"
(cd "$ROOT/apps/cli" && bun run build)

BIN_SRC="$ROOT/apps/cli/dist/index.js"
chmod +x "$BIN_SRC"

BIN_DIR=""
for candidate in "$HOME/.local/bin" "/usr/local/bin"; do
  if [[ -d "$candidate" && -w "$candidate" ]]; then
    BIN_DIR="$candidate"
    break
  fi
done
if [[ -z "$BIN_DIR" ]]; then
  BIN_DIR="$HOME/.local/bin"
  mkdir -p "$BIN_DIR"
fi

ln -sf "$BIN_SRC" "$BIN_DIR/brandnana"
echo "✓ brandnana installed to $BIN_DIR/brandnana"

if ! command -v brandnana >/dev/null 2>&1; then
  echo ""
  echo "Note: $BIN_DIR is not on your PATH. Add this to your shell rc:"
  echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi

echo ""
brandnana --version || true
