#!/usr/bin/env bash
# Build the in-sandbox Go toolchain (wb-fm0.5): yaegi (a pure-Go interpreter) cross-compiled to
# wasm32-wasip1 by the NATIVE Go toolchain. This is trusted, one-time PROVISIONING (like building
# mrustc.wasm / clang.wasm) — the native Go compiler only builds the trusted runner; it never
# compiles or runs untrusted user Go. At runtime yaegi-run.wasm INTERPRETS untrusted Go ENTIRELY
# in the wasm sandbox (zero native execution of user code). Idempotent: skips if already built.
# Last stdout line = the yaegi-run.wasm path.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"          # compilers/go
ROOT="$SD/yaegi-root"
WASM="$ROOT/yaegi-run.wasm"
exec 3>&1 1>&2

command -v go >/dev/null || { echo "[go] native Go toolchain required to build yaegi-run.wasm"; exit 1; }
ver="$(go env GOVERSION 2>/dev/null || echo unknown)"
echo "[go] using $ver (need >=1.21 for GOOS=wasip1)"

cd "$ROOT"
[ -f go.mod ] || { echo "[go] go mod init"; go mod init wbyaegi >/dev/null; }
grep -q 'traefik/yaegi' go.mod 2>/dev/null || { echo "[go] go get yaegi"; go get github.com/traefik/yaegi/interp github.com/traefik/yaegi/stdlib >/dev/null 2>&1; }

if [ ! -f "$WASM" ] || [ "$ROOT/runner.go" -nt "$WASM" ]; then
  echo "[go] GOOS=wasip1 GOARCH=wasm go build -> yaegi-run.wasm"
  GOOS=wasip1 GOARCH=wasm go build -o "$WASM" .
fi

echo "[go] DONE — $WASM ($(du -h "$WASM" | cut -f1))"
echo "$WASM" 1>&3
