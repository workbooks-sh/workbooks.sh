#!/usr/bin/env bash
# dasel (Go, multi-format JSON/YAML/TOML/XML/CSV query) -> wasm32-wasip1 via native Go (esbuild/yq pattern).
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; ROOT="$SD/dasel-root"; WASM="$SD/dasel.wasm"; VERSION="v2.8.1"; STAMP="$SD/.dasel-version"
exec 3>&1 1>&2
command -v go >/dev/null || { echo "[dasel] native Go required"; exit 1; }
if [ -f "$WASM" ] && [ "$(cat "$STAMP" 2>/dev/null||true)" = "$VERSION" ]; then echo "[dasel] up to date"; echo "$WASM" 1>&3; exit 0; fi
mkdir -p "$ROOT"; cd "$ROOT"; [ -f go.mod ] || go mod init wbdasel >/dev/null
go get "github.com/tomwright/dasel/v2/cmd/dasel@$VERSION" >/dev/null 2>&1
GOOS=wasip1 GOARCH=wasm go build -trimpath -ldflags=-buildid= -o "$WASM" github.com/tomwright/dasel/v2/cmd/dasel
[ -f "$WASM" ] || { echo "[dasel] build failed"; exit 1; }
printf '%s' "$VERSION" > "$STAMP"; echo "[dasel] DONE $WASM ($(du -h "$WASM"|cut -f1))"; echo "$WASM" 1>&3
