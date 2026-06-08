#!/usr/bin/env bash
# wb-v3d: ONE command to provision the proc-macro-capable Rust-in-WASM runtime for another agent /
# CI / a fresh machine. Builds exactly what the runtime needs and nothing it doesn't:
#
#   1. core lane  — clang.wasm, mrustc.wasm (+ mrustc_pm.wasm), native mrustc+minicargo, 1.54 src
#                   (the 1.54 *libstd* is SKIPPED — the runtime only uses the 1.74 lane; only the
#                    legacy proof scripts need output-wasi/).
#   2. 1.74 lane  — rustc-1.74 src + the 1.74 libstd + libproc_macro (output-wasi-174/).
#   3. wasmex     — the vendored, exception-enabled NIF (so mrustc_pm.wasm runs under Wasmex).
#
# Idempotent: every step fast-skips when its artifact already exists. Run from anywhere.
set -euo pipefail
RUNTIME="$(cd "$(dirname "$0")/.." && pwd)"   # runtime/
RUST="$RUNTIME/compilers/rust"
say(){ echo "[provision-runtime] $*" >&2; }

say "1/3 core Rust-in-WASM lane (clang, mrustc.wasm + mrustc_pm.wasm, native mrustc) — skip 1.54 libstd"
WB_SKIP_154_LIBSTD=1 bash "$RUST/provision-rust.sh"

say "2/3 the 1.74 lane (libstd + libproc_macro — the lane the runtime actually uses)"
bash "$RUST/provision-rust-174.sh"

[ -f "$RUST/mrustc-root/mrustc_pm.wasm" ] || { say "ERROR: mrustc_pm.wasm not produced by build.sh"; exit 1; }

say "3/3 vendored wasmex NIF (wasm exception proposal enabled for proc-macro expansion)"
( cd "$RUNTIME" && mix deps.compile wasmex )

say "DONE — proc-macros compile AND execute in-sandbox. Sanity: bash $RUST/procmacro-bridge-e2e.sh"
