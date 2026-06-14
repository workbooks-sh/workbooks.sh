#!/usr/bin/env bash
# yq's sibling: gojq (Go jq) -> wasm32-wasip1 via native Go (provision-time). OUTPUT runs sandboxed.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; ROOT="$SD/gojq-root"; WASM="$SD/gojq.wasm"; VERSION="v0.12.19"; STAMP="$SD/.gojq-version"
exec 3>&1 1>&2
command -v go >/dev/null || { echo "[gojq] native Go required"; exit 1; }
if [ -f "$WASM" ] && [ "$(cat "$STAMP" 2>/dev/null||true)" = "$VERSION" ]; then echo "[gojq] up to date"; echo "$WASM" 1>&3; exit 0; fi
mkdir -p "$ROOT"; cd "$ROOT"; [ -f go.mod ] || go mod init wbgojq >/dev/null
go get "github.com/itchyny/gojq/cmd/gojq@$VERSION" >/dev/null 2>&1
GOOS=wasip1 GOARCH=wasm go build -trimpath -ldflags=-buildid= -o "$WASM" github.com/itchyny/gojq/cmd/gojq
[ -f "$WASM" ] || { echo "[gojq] build failed"; exit 1; }
printf '%s' "$VERSION" > "$STAMP"
echo "[gojq] DONE $WASM ($(du -h "$WASM"|cut -f1))"; echo "$WASM" 1>&3
