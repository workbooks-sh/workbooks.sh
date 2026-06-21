#!/usr/bin/env bash
# work svelte lane — vendor the single-file Svelte compiler (svelte 4, compiler.cjs) loadable inside
# qjs-run.wasm. The driver svelte_compile.js loads node_modules/svelte/compiler.cjs from the
# files-map and runs svelte.compile() on each .svelte source → client JS (zero native execution).
#
# Svelte's compiler is self-contained (~1.5MB) and parses fast in QuickJS, so — unlike the solid lane —
# it does NOT need StarlingMonkey. Just fetch the single file.
set -euo pipefail
cd "$(dirname "$0")"
SVELTE_VER="${SVELTE_VER:-4.2.19}"
mkdir -p vendor
if [ -f vendor/compiler.cjs ]; then
  echo "[svelte] vendor/compiler.cjs present ($(wc -c < vendor/compiler.cjs) bytes)"
else
  echo "[svelte] fetch svelte@$SVELTE_VER compiler.cjs"
  curl -fsSL "https://unpkg.com/svelte@$SVELTE_VER/compiler.cjs" -o vendor/compiler.cjs
fi
