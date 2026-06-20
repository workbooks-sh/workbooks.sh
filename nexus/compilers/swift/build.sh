#!/usr/bin/env bash
# Provision the Swift lane: the official Swift 6.2 toolchain + the Swift SDK for WebAssembly (WASI).
# Swift cross-compiles to wasm with a NATIVE swiftc (there is no wasm-hosted Swift compiler upstream
# yet — see Nexus.Compilers.Swift), so we stage the native toolchain and install the wasm SDK into it.
# The produced artifacts are still sandboxed wasm components; only the compile step is native.
#
# Contract (build_and_register_script): last stdout line = the swiftc path; all progress → stderr.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SD/swift-root"
SWIFTC="$ROOT/usr/bin/swiftc"

# Pinned Swift release + its WebAssembly SDK. Bump together; the SDK is keyed to the toolchain build.
SWIFT_VERSION="6.2"
SDK_ID="swift-wasm"
# The Swift SDK for WebAssembly bundle (swift.org publishes a checksum alongside; verify on fetch).
SDK_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/wasm/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE_wasm.artifactbundle.tar.gz"
SDK_SHA="${SWIFT_WASM_SDK_SHA:-}"   # set to enforce; empty = swift sdk install verifies its own checksum

exec 3>&1 1>&2   # progress → stderr; fd 3 = the one stdout line (the swiftc path)

# 1) The native Swift toolchain. On a provisioned macOS/Linux box this is usually already on PATH
#    (Xcode / swiftly / the .pkg). If a system swiftc exists we symlink it into swift-root rather than
#    re-downloading a multi-GB toolchain; otherwise the operator installs it (swiftly recommended).
if [ ! -x "$SWIFTC" ]; then
  if command -v swiftc >/dev/null 2>&1; then
    SYS="$(dirname "$(dirname "$(command -v swiftc)")")"   # …/usr
    echo "[swift] linking system toolchain from $SYS"
    mkdir -p "$ROOT"
    ln -sfn "$SYS" "$ROOT/usr"
  else
    echo "[swift] no native swiftc found — install Swift $SWIFT_VERSION (https://swift.org/install,"
    echo "[swift] e.g. \`curl -L https://swiftlang.github.io/swiftly/swiftly-install.sh | bash\`)"
    exit 1
  fi
fi

# 2) The Swift SDK for WebAssembly. Installed into the toolchain's SDK store; the lane passes
#    `-swift-sdk $SDK_ID`. Idempotent — `swift sdk install` is a no-op if already present.
if ! "$ROOT/usr/bin/swift" sdk list 2>/dev/null | grep -q "$SDK_ID"; then
  echo "[swift] installing WebAssembly SDK: $SDK_URL"
  if [ -n "$SDK_SHA" ]; then
    "$ROOT/usr/bin/swift" sdk install "$SDK_URL" --checksum "$SDK_SHA"
  else
    "$ROOT/usr/bin/swift" sdk install "$SDK_URL"
  fi
fi

[ -x "$ROOT/usr/bin/swiftc" ] || { echo "[swift] no swiftc after provision"; exit 1; }
echo "$ROOT/usr/bin/swiftc" 1>&3
