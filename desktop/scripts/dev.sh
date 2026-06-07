#!/usr/bin/env bash
# Run the desktop app in dev — builds the `wb` escript (the deploy-kit the shell
# drives) and points the Tauri shell at it via WB_BIN, then launches `tauri dev`.
# Avoids touching ~/.local/bin/wb (the legacy binary).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "==> building wb escript"
( cd "$ROOT/runtime" && mix escript.build >/dev/null )
export WB_BIN="$ROOT/runtime/wb"
echo "    WB_BIN=$WB_BIN"

echo "==> tauri dev"
cd "$ROOT/desktop"
exec bun run tauri dev
