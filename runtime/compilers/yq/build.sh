#!/usr/bin/env bash
# Build the yq lane: yq (Go) cross-compiled to wasm32-wasip1 by NATIVE Go (provision-time, like esbuild).
# Trusted one-time build; the OUTPUT runs sandboxed under wasmtime. We produce the artifact, so
# reproducibility = pin inputs (Go ver + yq module ver) + -trimpath. Idempotent via a version stamp.
# Last stdout line = the yq.wasm path.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SD/yq-root"; WASM="$SD/yq.wasm"; VERSION="v4.53.3"; STAMP="$SD/.yq-version"
exec 3>&1 1>&2
command -v go >/dev/null || { echo "[yq] native Go required"; exit 1; }
echo "[yq] $(go env GOVERSION), pinning yq $VERSION"
if [ -f "$WASM" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$VERSION" ]; then
  echo "[yq] up to date"; echo "$WASM" 1>&3; exit 0
fi
mkdir -p "$ROOT"; cd "$ROOT"
[ -f go.mod ] || go mod init wbyq >/dev/null
go get "github.com/mikefarah/yq/v4@$VERSION" >/dev/null 2>&1
GOOS=wasip1 GOARCH=wasm go build -trimpath -ldflags=-buildid= -o "$WASM" github.com/mikefarah/yq/v4
[ -f "$WASM" ] || { echo "[yq] build produced nothing"; exit 1; }
printf '%s' "$VERSION" > "$STAMP"
echo "[yq] DONE $WASM ($(du -h "$WASM"|cut -f1)) sha256=$(shasum -a 256 "$WASM"|cut -d' ' -f1)"
echo "$WASM" 1>&3
