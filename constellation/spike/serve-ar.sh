#!/usr/bin/env bash
# AR lane — Granite-4.1-3B Q4 on llama-server, Metal-accelerated, OpenAI-compatible.
# This is the CPU/deliberate lane. On Apple silicon Metal offload uses the GPU;
# -ngl 0 forces pure-CPU if you want the literal CPU/GPU split for the two-lane test.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="${MODEL:-$DIR/models/granite-4.1-3b-Q4_K_M.gguf}"
PORT="${PORT:-8081}"
NGL="${NGL:-99}"   # 99 = all layers on Metal/GPU; set NGL=0 for pure CPU
exec llama-server -m "$MODEL" --port "$PORT" -ngl "$NGL" -c 8192 \
  --host 127.0.0.1 --jinja
