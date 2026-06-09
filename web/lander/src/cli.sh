#!/bin/sh
# Workbooks CLI installer.
#
#   curl -fsSL https://workbooks.sh/cli.sh | sh
#
# Downloads the canonical `wb` binary (the Rust CLI built from cli/) from the
# latest `wb-v*` GitHub Release and installs it to ~/.local/bin. No Erlang, no
# Node — one static binary. (npm alternative:  npm i -g @work.books/cli)
#
# Env overrides:
#   WB_CLI_VERSION    pin a version, e.g. WB_CLI_VERSION=0.1.0
#   WB_INSTALL_DIR    install location (default ~/.local/bin)
#   WB_REPO           owner/repo (default workbooks-sh/workbooks.sh)
set -eu

REPO="${WB_REPO:-workbooks-sh/workbooks.sh}"
API="https://api.github.com/repos/${REPO}"
DIR="${WB_INSTALL_DIR:-$HOME/.local/bin}"

say()  { printf '\033[1;34m::\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$1" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }
need curl

# ---- platform → asset name (matches cli-release.yml) ------------------------
OS="$(uname -s)"; ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="x64" ;;
  *) die "unsupported CPU architecture: $ARCH" ;;
esac
case "$OS" in
  Darwin) ASSET="wb-darwin-${ARCH}" ;;
  Linux)  ASSET="wb-linux-${ARCH}" ;;
  *) die "unsupported OS: $OS (try: npm i -g @work.books/cli)" ;;
esac

# ---- resolve the release tag ------------------------------------------------
if [ -n "${WB_CLI_VERSION:-}" ]; then
  TAG="wb-v${WB_CLI_VERSION}"
else
  say "Finding the latest wb release…"
  # newest release whose tag starts with wb-v
  TAG="$(curl -fsSL "${API}/releases" \
    | grep -o '"tag_name": *"wb-v[^"]*"' \
    | head -n1 | sed 's/.*"\(wb-v[^"]*\)"/\1/')"
  [ -n "$TAG" ] || die "no wb-v* release found for ${REPO}"
fi

URL="https://github.com/${REPO}/releases/download/${TAG}/${ASSET}"
say "Downloading ${ASSET} (${TAG})…"
mkdir -p "$DIR"
TMP="$(mktemp)"
curl -fSL "$URL" -o "$TMP" || die "download failed: $URL"
chmod +x "$TMP"
mv "$TMP" "$DIR/wb"

say "Installed wb → $DIR/wb"
case ":$PATH:" in
  *":$DIR:"*) ;;
  *) say "Add to PATH:  export PATH=\"$DIR:\$PATH\"" ;;
esac
"$DIR/wb" --version 2>/dev/null || true
