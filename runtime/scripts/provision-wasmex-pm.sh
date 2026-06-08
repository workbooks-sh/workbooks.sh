#!/usr/bin/env bash
# wb-v3d: Workbooks.ProcMacroHost runs mrustc_pm.wasm (C++ exception handling → exnref) under
# Wasmex, but the upstream wasmex NIF never enables wasmtime's exception-handling proposal, and it
# ships a precompiled NIF. This idempotently patches the NIF config and forces a source rebuild.
#
# Run from runtime/ after `mix deps.get`. Safe to re-run.
set -euo pipefail
SD="$(cd "$(dirname "$0")/.." && pwd)"   # runtime/
ENG="$SD/deps/wasmex/native/wasmex/src/engine.rs"
[ -f "$ENG" ] || { echo "[wasmex-pm] $ENG not found — run 'mix deps.get' first"; exit 1; }

if grep -q "wasm_exceptions(true)" "$ENG"; then
  echo "[wasmex-pm] engine.rs already patched"
else
  echo "[wasmex-pm] enabling wasm exception-handling proposal in engine.rs"
  # Insert right after the debug_info config line.
  python3 - "$ENG" <<'PY'
import sys
f = sys.argv[1]; s = open(f).read()
anchor = "    config.debug_info(engine_config.debug_info);\n"
add = ("    // wb-v3d: enable the wasm exception-handling proposal so mrustc_pm.wasm (C++ EH →\n"
       "    // exnref) runs under Wasmex. exnref rides on function-references; enable both.\n"
       "    config.wasm_function_references(true);\n"
       "    config.wasm_exceptions(true);\n")
assert anchor in s, "anchor line not found — wasmex engine.rs layout changed"
open(f, "w").write(s.replace(anchor, anchor + add, 1))
PY
fi

echo "[wasmex-pm] rebuilding the wasmex NIF from source (WASMEX_BUILD=1; compiles wasmtime)…"
cd "$SD"
WASMEX_BUILD=1 mix deps.compile wasmex --force
echo "[wasmex-pm] done — Wasmex can now run exception-handling wasm (mrustc_pm.wasm)"
