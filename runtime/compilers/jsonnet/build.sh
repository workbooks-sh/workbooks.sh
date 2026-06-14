#!/usr/bin/env bash
# jsonnet (google/go-jsonnet, config templating language) -> wasm32-wasip1 via native Go (yq/esbuild pattern).
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; ROOT="$SD/jsonnet-root"; WASM="$SD/jsonnet.wasm"; VERSION="v0.22.0"; STAMP="$SD/.jsonnet-version"
exec 3>&1 1>&2
command -v go >/dev/null || { echo "[jsonnet] native Go required"; exit 1; }
if [ -f "$WASM" ] && [ "$(cat "$STAMP" 2>/dev/null||true)" = "$VERSION" ]; then echo "[jsonnet] up to date"; echo "$WASM" 1>&3; exit 0; fi
mkdir -p "$ROOT"; cd "$ROOT"; [ -f go.mod ] || go mod init wbjsonnet >/dev/null
go get "github.com/google/go-jsonnet/cmd/jsonnet@$VERSION" >/dev/null 2>&1
GOOS=wasip1 GOARCH=wasm go build -trimpath -ldflags=-buildid= -o "$WASM" github.com/google/go-jsonnet/cmd/jsonnet
[ -f "$WASM" ] || { echo "[jsonnet] build failed"; exit 1; }
printf '%s' "$VERSION" > "$STAMP"; echo "[jsonnet] DONE $WASM ($(du -h "$WASM"|cut -f1))"; echo "$WASM" 1>&3
