#!/usr/bin/env bash
# stage-eval-host.sh — build + stage the StarlingMonkey JS eval-host (priv/eval-host.wasm).
#
# The runtime engine `Nexus.JsEngine` runs: a JS string is fed to its `run(input)` export as data
# (js_dom/browse + the Elixir-toolkit lane). It IMPORTS the `work:evalhost/toolkit-caps` interface
# (the capability bridge); the host satisfies those imports per-call (Nexus.Toolkit.Caps + the
# default stubs in Nexus.JsEngine), so a plain eval works and a granted toolkit gets path-scoped caps.
#
# This is the exact mirror of stage-cli.sh: produce the gitignored artifact from its recipe
# (build/eval-host/) and copy it into priv/, BEFORE the image build COPYs nexus/ in. Idempotent —
# short-circuits when the artifact is newer than the recipe.
#
# Componentize-js (jco) is a BUILD-TIME native-node toolchain (like zig for the reactor / rustc for
# the rust lane). It runs ONLY here, on the build runner — never in a running nexus. The output is a
# pure-wasm component the runtime loads under wasmtime.
set -euo pipefail

cd "$(dirname "$0")/.."                        # nexus/
REC="build/eval-host"
OUT="priv/eval-host.wasm"

[ -f "$REC/evalhost.js" ] || { echo "[stage-eval-host] recipe missing: $REC/evalhost.js" >&2; exit 1; }

if [ -f "$OUT" ] && [ "$OUT" -nt "$REC/evalhost.js" ] && [ "$OUT" -nt "$REC/evalhost.wit" ]; then
  echo "[stage-eval-host] up to date: $OUT ($(du -h "$OUT" | cut -f1))"
  exit 0
fi

# jco — use a binary on PATH if present, else npx with the SCOPED packages pinned (a bare `jco` on npm
# is a dependency-confusion placeholder; always use @bytecodealliance/*).
if [ -n "${JCO:-}" ]; then
  RUN_JCO="$JCO"
elif command -v jco >/dev/null 2>&1; then
  RUN_JCO="jco"
else
  RUN_JCO="npx -y -p @bytecodealliance/jco -p @bytecodealliance/componentize-js jco"
fi

mkdir -p priv
echo "[stage-eval-host] componentize $REC/evalhost.js -> $OUT"
$RUN_JCO componentize "$REC/evalhost.js" \
  --wit "$REC/evalhost.wit" --world-name workbook \
  -o "$OUT"

echo "[stage-eval-host] staged $OUT ($(du -h "$OUT" | cut -f1))"
