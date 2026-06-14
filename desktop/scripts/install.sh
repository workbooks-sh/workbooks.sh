#!/bin/sh
# Workbooks desktop installer.
#
#   curl -fsSL https://workbooks.sh/install.sh | sh
#
# Downloads the latest Workbooks desktop app from GitHub Releases and installs
# it. The app is offline-first; on first launch its built-in wizard gets the
# runtime engine running — a fast local microVM (vfkit: direct-kernel boot, no
# daemon; falls back to docker/krunvm), or a cloud engine. This script only puts
# the app in place; the wizard fetches the runtime disk + boots it on your
# consent when you choose the local engine.
#
# Env overrides:
#   WB_VERSION      pin a release, e.g. WB_VERSION=0.1.0 (tag desktop-v0.1.0)
#   WB_INSTALL_DIR  where to put the binary on Linux (default ~/.local/bin)
#   WB_REPO         override owner/repo (default workbooks-sh/workbooks.sh)
set -eu

REPO="${WB_REPO:-workbooks-sh/workbooks.sh}"
API="https://api.github.com/repos/${REPO}"

say()  { printf '\033[1;34m::\033[0m %s\n' "$1" >&2; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$1" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }
need curl

# ---- platform detection -----------------------------------------------------
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64|aarch64) ARCH="arm64" ;;
  x86_64|amd64)  ARCH="x86_64" ;;
  *) die "unsupported CPU architecture: $ARCH" ;;
esac

# ---- find the release -------------------------------------------------------
if [ -n "${WB_VERSION:-}" ]; then
  REL_URL="${API}/releases/tags/desktop-v${WB_VERSION}"
  say "Looking up Workbooks desktop v${WB_VERSION}…"
else
  REL_URL="${API}/releases/latest"
  say "Looking up the latest Workbooks desktop release…"
fi

REL_JSON="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$REL_URL")" \
  || die "could not reach GitHub Releases. Check your connection, or download from https://github.com/${REPO}/releases"

TAG="$(printf '%s' "$REL_JSON" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
[ -n "$TAG" ] || die "no published desktop release found. Grab a bundle from https://github.com/${REPO}/releases"

# All asset download URLs in the release.
ASSETS="$(printf '%s' "$REL_JSON" | grep '"browser_download_url"' | sed -E 's/.*"(https:[^"]+)".*/\1/')"
[ -n "$ASSETS" ] || die "release ${TAG} has no downloadable assets yet"

# Pick the asset matching this platform. We match on substrings tauri-action
# bakes into bundle names rather than an exact filename, so a version bump or a
# naming tweak doesn't break the installer.
pick() {
  # $1..$n: grep -E patterns tried in order; first asset matching one wins.
  for pat in "$@"; do
    hit="$(printf '%s\n' "$ASSETS" | grep -Ei "$pat" | head -n1)"
    [ -n "$hit" ] && { printf '%s' "$hit"; return 0; }
  done
  return 1
}

case "$OS" in
  Darwin)
    if [ "$ARCH" = "arm64" ]; then
      URL="$(pick 'aarch64.*\.dmg' 'arm64.*\.dmg' '\.dmg$')" || die "no macOS .dmg in release ${TAG}"
    else
      URL="$(pick 'x64.*\.dmg' 'x86_64.*\.dmg' 'intel.*\.dmg' '\.dmg$')" || die "no macOS .dmg in release ${TAG}"
    fi
    ;;
  Linux)
    if [ "$ARCH" = "arm64" ]; then
      URL="$(pick 'aarch64.*\.AppImage' 'arm64.*\.AppImage' '\.AppImage$')" || die "no Linux .AppImage in release ${TAG}"
    else
      URL="$(pick 'amd64.*\.AppImage' 'x86_64.*\.AppImage' 'x64.*\.AppImage' '\.AppImage$')" || die "no Linux .AppImage in release ${TAG}"
    fi
    ;;
  *)
    die "this installer supports macOS and Linux. On Windows, download the .msi from https://github.com/${REPO}/releases"
    ;;
esac

FILE="$(basename "$URL")"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/workbooks.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
say "Downloading ${FILE} (${TAG})…"
curl -fSL --progress-bar "$URL" -o "${TMP}/${FILE}" || die "download failed: $URL"

# ---- install ----------------------------------------------------------------
case "$OS" in
  Darwin)
    say "Mounting ${FILE}…"
    MNT="$(mktemp -d "${TMPDIR:-/tmp}/workbooks-mnt.XXXXXX")"
    hdiutil attach -nobrowse -quiet -mountpoint "$MNT" "${TMP}/${FILE}" \
      || die "could not mount the disk image"
    APP="$(/bin/ls -d "$MNT"/*.app 2>/dev/null | head -n1)"
    if [ -z "$APP" ]; then
      hdiutil detach -quiet "$MNT" || true
      die "no .app found inside ${FILE}"
    fi
    DEST="/Applications/$(basename "$APP")"
    say "Installing to ${DEST}…"
    rm -rf "$DEST"
    # Try /Applications; fall back to ~/Applications if it isn't writable.
    if ! cp -R "$APP" "$DEST" 2>/dev/null; then
      DEST="$HOME/Applications/$(basename "$APP")"
      mkdir -p "$HOME/Applications"
      rm -rf "$DEST"
      cp -R "$APP" "$DEST" || { hdiutil detach -quiet "$MNT" || true; die "could not copy the app"; }
    fi
    hdiutil detach -quiet "$MNT" || true
    # Strip the quarantine flag so Gatekeeper doesn't block the first open
    # (unsigned/ad-hoc builds). No-op if already clear.
    xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
    say "Installed. Launch it with:  open '$DEST'"
    ;;
  Linux)
    DIR="${WB_INSTALL_DIR:-$HOME/.local/bin}"
    mkdir -p "$DIR"
    DEST="${DIR}/workbooks"
    say "Installing to ${DEST}…"
    mv "${TMP}/${FILE}" "$DEST"
    chmod +x "$DEST"
    case ":${PATH}:" in
      *":${DIR}:"*) : ;;
      *) warn "${DIR} is not on your PATH — add it, or run the app by its full path." ;;
    esac
    say "Installed. Launch it with:  workbooks"
    ;;
esac

say "Done. On first launch, the in-app wizard connects an engine — local microVM or cloud. It's optional; Workbooks runs offline without it."
