#!/usr/bin/env bash
# work solid lane — vendor a single-file @babel/standalone bundle with babel-preset-solid registered,
# loadable inside qjs-run.wasm (zero native execution at compile time). Mirrors the svelte lane: the
# Solid JSX compiler is babel + a preset, so we bundle them into one IIFE that sets globalThis.Babel.
#
# Reproduce (needs bun or npm + a bundler) from this dir:
#   mkdir -p vendor && cd /tmp && rm -rf solidbuild && mkdir solidbuild && cd solidbuild
#   printf 'import * as Babel from "@babel/standalone";\nimport p from "babel-preset-solid";\nBabel.registerPreset("solid", p);\nglobalThis.Babel = Babel;\n' > entry.js
#   bun add @babel/standalone babel-preset-solid
#   bun build entry.js --outfile=babel.js --target=browser --format=iife
#   cp babel.js <this-dir>/vendor/babel.js
#
# The driver solid_compile.js (this dir) loads vendor/babel.js from the hoisted node_modules path in
# the files-map and runs Babel.transform(src, {presets:['solid']}) on each .jsx/.tsx entry.
set -euo pipefail
echo "[solid] vendor/babel.js is prebuilt (see header). Nothing to compile at stage time."
