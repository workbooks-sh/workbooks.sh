#!/usr/bin/env bash
# work solid lane — bundle @babel/standalone + babel-preset-solid into one IIFE that exposes
# globalThis.solidTransform(code, filename) -> compiled Solid JS. The bundle runs on StarlingMonkey
# (Nexus.JsEngine, SpiderMonkey→wasm) — ~1.2s, vs ~80s on QuickJS which can't parse a multi-MB babel.
#
# Two gotchas baked into the recipe:
#   * babel-preset-solid (dom-expressions) imports node:assert — a browser bundler stubs it to an
#     empty object → "_assert is not a function". We --alias it to a real assert shim.
#   * StarlingMonkey has no Node globals; the Elixir lane (Nexus.Compilers.Js.transpile/3) prepends a
#     `process` shim before this bundle at eval time.
#
# Reproduce (needs bun + esbuild via bunx) from this dir:
#   bun add @babel/standalone babel-preset-solid
#   bunx esbuild entry.js --bundle --outfile=vendor/babel.js --format=iife --platform=browser \
#     --alias:assert="$PWD/assert-shim.js" --alias:node:assert="$PWD/assert-shim.js" \
#     --define:process.env.NODE_ENV='"production"'
#
# entry.js registers the preset + defines solidTransform; assert-shim.js is the node:assert polyfill.
# Both live in this dir; vendor/babel.js is the gitignored output shipped via the compilers package.
set -euo pipefail
cd "$(dirname "$0")"
[ -f vendor/babel.js ] && echo "[solid] vendor/babel.js present ($(wc -c < vendor/babel.js) bytes)" || {
  echo "[solid] building vendor/babel.js …"
  bun add @babel/standalone babel-preset-solid
  mkdir -p vendor
  bunx esbuild entry.js --bundle --outfile=vendor/babel.js --format=iife --platform=browser \
    --alias:assert="$PWD/assert-shim.js" --alias:node:assert="$PWD/assert-shim.js" \
    --define:process.env.NODE_ENV='"production"'
}
