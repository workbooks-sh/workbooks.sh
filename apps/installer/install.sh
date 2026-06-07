#!/usr/bin/env sh
# brandnana installer — https://brandnana.net
set -eu

# Detect OS + arch
case "$(uname -s)" in
  Darwin) OS=darwin ;;
  Linux)  OS=linux  ;;
  *) echo "unsupported OS: $(uname -s)"; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=x64   ;;
  *) echo "unsupported arch: $(uname -m)"; exit 1 ;;
esac

BINARY="brandnana-${OS}-${ARCH}"
VERSION="${BRANDNANA_VERSION:-latest}"
URL="https://install.brandnana.net/binaries/${VERSION}/${BINARY}"
DEST="${BRANDNANA_INSTALL_DIR:-${HOME}/.local/bin}"

mkdir -p "$DEST"
echo "[brandnana] fetching $BINARY..."
curl -fL --progress-bar "$URL" -o "$DEST/brandnana"
chmod +x "$DEST/brandnana"

# PATH check
case ":$PATH:" in
  *":$DEST:"*) ;;
  *) echo
     echo "  add $DEST to your PATH:"
     echo "  echo 'export PATH=\$PATH:$DEST' >> ~/.zshrc  # or ~/.bashrc"
     ;;
esac

echo
echo "[brandnana] installed: $($DEST/brandnana --version 2>/dev/null || echo unknown)"
echo
echo "  next: brandnana auth login"
echo "  docs: https://brandnana.net"
