#!/usr/bin/env bash
# Build the C compiler (c4 — a real self-hosting C-subset compiler) to wasm32-wasi.
# No LLVM. Prints the output wasm path as the LAST stdout line (build noise → stderr).
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec 3>&1 1>&2
OUT="${TMPDIR:-/tmp}/wb-cc-c4.wasm"
zig cc -O2 -target wasm32-wasi -D_WASI_EMULATED_SIGNAL "$SD/c4.c" -o "$OUT" -lwasi-emulated-signal
echo "$OUT" >&3
