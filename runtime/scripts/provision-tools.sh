#!/usr/bin/env bash
# Provision the pinned WASM toolchain into runtime/build/tools/. Idempotent: a tool
# already present is skipped. Each asset is downloaded by pinned version, sha256-verified
# against scripts/tools.lock, and installed. This is the single source of truth for the
# native tools the build path shells out to (javy, wasm-tools, wac) plus the wasi adapter.
#
#   Versions are pinned below; shas live in scripts/tools.lock (one per platform asset).
#   To bump: change the version here, re-download, and update the matching sha lines.
set -euo pipefail

JAVY_V=8.1.1
WASMTOOLS_V=1.251.0
WAC_V=0.10.0
WASMTIME_V=45.0.1   # only the wasi adapter asset

SD="$(cd "$(dirname "$0")" && pwd)"
RT="$(cd "$SD/.." && pwd)"
TOOLS="$RT/build/tools"
LOCK="$SD/tools.lock"
mkdir -p "$TOOLS"

uname_s="$(uname -s)"; uname_m="$(uname -m)"
case "$uname_s" in
  Darwin) javy_os=macos; wt_os=macos;  wac_os=apple-darwin ;;
  Linux)  javy_os=linux; wt_os=linux;  wac_os=unknown-linux-musl ;;
  *) echo "[tools] unsupported OS: $uname_s" >&2; exit 1 ;;
esac
case "$uname_m" in
  arm64|aarch64) javy_arch=arm;    wt_arch=aarch64; wac_arch=aarch64 ;;
  x86_64|amd64)  javy_arch=x86_64; wt_arch=x86_64;  wac_arch=x86_64 ;;
  *) echo "[tools] unsupported arch: $uname_m" >&2; exit 1 ;;
esac

sha_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" | cut -d' ' -f1; }

# expected sha for an asset name, from the lock
expect() {
  local name="$1" sha
  sha="$(awk -v n="$name" '$1==n{print $2}' "$LOCK")"
  [ -n "$sha" ] || { echo "[tools] no sha for '$name' in $LOCK — add it (see header)" >&2; exit 1; }
  echo "$sha"
}

verify() { # file expected-sha asset-name
  local got; got="$(sha_of "$1")"
  if [ "$got" != "$2" ]; then
    echo "[tools] SHA MISMATCH for $3" >&2
    echo "  expected $2" >&2; echo "  got      $got" >&2
    exit 1
  fi
}

fetch() { # url out
  echo "[tools] fetching $(basename "$1")" >&2
  # HARD bounds: an un-timed-out CDN fetch here froze the whole `mix test` suite
  # for 15-20 min at 0% CPU holding ESTABLISHED conns (wb-1ffa). --connect-timeout
  # bounds the handshake, --max-time the whole transfer, --retry rides transient
  # CDN blips. Better a clean failure than an infinite stall.
  curl -fsSL --connect-timeout 20 --max-time 180 --retry 2 --retry-delay 2 -o "$2" "$1"
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# --- javy: gzipped single binary ---
if [ ! -x "$TOOLS/javy" ]; then
  asset="javy-${javy_arch}-${javy_os}-v${JAVY_V}.gz"
  url="https://github.com/bytecodealliance/javy/releases/download/v${JAVY_V}/${asset}"
  fetch "$url" "$tmp/$asset"
  verify "$tmp/$asset" "$(expect "$asset")" "$asset"
  gunzip -c "$tmp/$asset" > "$TOOLS/javy"
  chmod +x "$TOOLS/javy"
  echo "[tools] installed javy $JAVY_V" >&2
fi

# --- wasm-tools: tar.gz with a versioned dir containing the binary ---
if [ ! -x "$TOOLS/wasm-tools" ]; then
  asset="wasm-tools-${WASMTOOLS_V}-${wt_arch}-${wt_os}.tar.gz"
  url="https://github.com/bytecodealliance/wasm-tools/releases/download/v${WASMTOOLS_V}/${asset}"
  fetch "$url" "$tmp/$asset"
  verify "$tmp/$asset" "$(expect "$asset")" "$asset"
  tar -xzf "$tmp/$asset" -C "$tmp"
  found="$(find "$tmp" -type f -name wasm-tools -perm -u+x | head -1)"
  [ -n "$found" ] || { echo "[tools] wasm-tools binary not found in archive" >&2; exit 1; }
  cp "$found" "$TOOLS/wasm-tools"; chmod +x "$TOOLS/wasm-tools"
  echo "[tools] installed wasm-tools $WASMTOOLS_V" >&2
fi

# --- wac: single binary ---
if [ ! -x "$TOOLS/wac" ]; then
  asset="wac-cli-${wac_arch}-${wac_os}"
  url="https://github.com/bytecodealliance/wac/releases/download/v${WAC_V}/${asset}"
  fetch "$url" "$tmp/$asset"
  verify "$tmp/$asset" "$(expect "$asset")" "$asset"
  cp "$tmp/$asset" "$TOOLS/wac"; chmod +x "$TOOLS/wac"
  echo "[tools] installed wac $WAC_V" >&2
fi

# --- wasi adapter: platform-independent wasm ---
if [ ! -f "$TOOLS/wasi_snapshot_preview1.command.wasm" ]; then
  asset="wasi_snapshot_preview1.command.wasm"
  url="https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_V}/${asset}"
  fetch "$url" "$tmp/$asset"
  verify "$tmp/$asset" "$(expect "$asset")" "$asset"
  cp "$tmp/$asset" "$TOOLS/$asset"
  echo "[tools] installed wasi adapter (wasmtime $WASMTIME_V)" >&2
fi

echo "[tools] ok: $TOOLS" >&2
