#!/bin/sh
# wbx installer — the Workbooks CLI.
#
#   curl -fsSL https://workbooks.sh/cli.sh | sh
#
# Downloads the latest wbx binary from GitHub Releases (tags `wbx-v*`) and
# installs it. Prefer npm? `npm install -g @work.books/cli` does the same.
#
# Env overrides:
#   WBX_VERSION      pin a release, e.g. WBX_VERSION=0.12.0
#   WBX_INSTALL_DIR  install dir (default: /usr/local/bin if writable, else ~/.local/bin)
#   WBX_REPO         override owner/repo (default workbooks-sh/workbooks.sh)
set -eu

REPO="${WBX_REPO:-workbooks-sh/workbooks.sh}"
say() { printf '\033[1;32m::\033[0m %s\n' "$1" >&2; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$1" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || die "curl is required"

os="$(uname -s)"; arch="$(uname -m)"
case "$os" in
  Darwin) os=darwin ;;
  Linux)  os=linux ;;
  *) die "unsupported OS: $os (macOS + Linux today; Windows via WSL)" ;;
esac
case "$arch" in
  arm64|aarch64) arch=arm64 ;;
  x86_64|amd64)  arch=x64 ;;
  *) die "unsupported arch: $arch" ;;
esac
ASSET="wbx-${os}-${arch}"

if [ -n "${WBX_VERSION:-}" ]; then
  TAG="wbx-v${WBX_VERSION}"
else
  TAG="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=30" \
    | grep -o '"tag_name": *"wbx-v[^"]*"' | head -1 | sed 's/.*"\(wbx-v[^"]*\)"/\1/')"
  [ -n "$TAG" ] || die "no wbx-v* release found on ${REPO}"
fi

DIR="${WBX_INSTALL_DIR:-}"
if [ -z "$DIR" ]; then
  if [ -w /usr/local/bin ]; then DIR=/usr/local/bin; else DIR="$HOME/.local/bin"; fi
fi
mkdir -p "$DIR"

URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
say "downloading ${ASSET} (${TAG})…"
TMP="$(mktemp)"
curl -fsSL "$URL" -o "$TMP" || die "download failed: $URL"
chmod +x "$TMP"
mv "$TMP" "$DIR/wbx"
say "installed → $DIR/wbx"

case ":$PATH:" in
  *":$DIR:"*) ;;
  *) say "note: $DIR is not on your PATH — add: export PATH=\"$DIR:\$PATH\"" ;;
esac
"$DIR/wbx" --version >&2 || true
say "done. start with: wbx --help"
