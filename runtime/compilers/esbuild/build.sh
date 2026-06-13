#!/usr/bin/env bash
# Build the esbuild lane: esbuild (Go) cross-compiled to wasm32-wasip1 by the NATIVE Go toolchain.
# This is trusted, one-time PROVISIONING (like building yaegi-run.wasm / clang.wasm) — native Go only
# builds the trusted tool; it never compiles or runs untrusted user code. At runtime esbuild.wasm runs
# under wasmtime (which JITs it to native) and bundles/transforms entirely in the wasm sandbox.
#
# We are the PRODUCER of this artifact (no upstream wasm to fetch), so reproducibility = pin the INPUTS
# (Go version + esbuild module version) and record the OUTPUT sha256 — unlike clang/zig which sha-verify
# a fetched tarball. `-trimpath -ldflags=-buildid=` makes the Go build deterministic.
# Idempotent: skips if the pinned version is already built. Last stdout line = the esbuild.wasm path.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"          # compilers/esbuild
ROOT="$SD/esbuild-root"                        # isolated build module (deps live here, gitignored)
WASM="$SD/esbuild.wasm"                         # the staged artifact (matches stage-tools take + compilers.ex)
VERSION="v0.28.1"                              # pinned esbuild module version (bump deliberately)
STAMP="$SD/.esbuild-version"                    # records the built version for idempotency
exec 3>&1 1>&2

command -v go >/dev/null || { echo "[esbuild] native Go toolchain required to build esbuild.wasm"; exit 1; }
ver="$(go env GOVERSION 2>/dev/null || echo unknown)"
echo "[esbuild] using $ver (need >=1.21 for GOOS=wasip1), pinning esbuild $VERSION"

# Skip if already built at the pinned version.
if [ -f "$WASM" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$VERSION" ]; then
  echo "[esbuild] up to date ($VERSION) — $WASM"
  echo "$WASM" 1>&3
  exit 0
fi

mkdir -p "$ROOT"; cd "$ROOT"
[ -f go.mod ] || { echo "[esbuild] go mod init"; go mod init wbesbuild >/dev/null; }
echo "[esbuild] go get esbuild@$VERSION"
go get "github.com/evanw/esbuild/cmd/esbuild@$VERSION" >/dev/null 2>&1

echo "[esbuild] GOOS=wasip1 GOARCH=wasm go build -trimpath -> esbuild.wasm"
GOOS=wasip1 GOARCH=wasm go build -trimpath -ldflags=-buildid= -o "$WASM" github.com/evanw/esbuild/cmd/esbuild

[ -f "$WASM" ] || { echo "[esbuild] build produced no esbuild.wasm"; exit 1; }
printf '%s' "$VERSION" > "$STAMP"
sha="$(shasum -a 256 "$WASM" | cut -d' ' -f1)"
echo "[esbuild] DONE — $WASM ($(du -h "$WASM" | cut -f1)) sha256=$sha"
echo "$WASM" 1>&3
