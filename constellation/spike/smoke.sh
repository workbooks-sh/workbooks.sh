#!/usr/bin/env bash
# Smoke one GGUF: boot llama-server, run a work-component prompt, print reply + tok/s, stop.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="${1:?usage: smoke.sh <model.gguf> [port]}"
PORT="${2:-8090}"
LOG="/tmp/ether-smoke-$PORT.log"
pkill -f "port $PORT" 2>/dev/null || true
( llama-server -m "$DIR/models/$MODEL" --port "$PORT" -ngl 99 -c 4096 --host 127.0.0.1 --jinja >"$LOG" 2>&1 & )
until grep -qiE "server is listening|error loading|failed" "$LOG"; do sleep 2; done
grep -qi "error loading\|failed" "$LOG" && { echo "LOAD FAILED ($MODEL):"; tail -4 "$LOG"; exit 1; }
echo "== $MODEL =="
curl -s "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
 -d '{"messages":[{"role":"user","content":"Write a one-line HTML <work-card> custom element with a title attribute. Output only the tag."}],"max_tokens":80,"temperature":0}' \
 | python3 -c 'import sys,json;d=json.load(sys.stdin);t=d.get("timings",{});print("REPLY:",d["choices"][0]["message"]["content"].strip());print("decode tok/s:",round(t.get("predicted_per_second",0),1),"| prefill tok/s:",round(t.get("prompt_per_second",0),1))'
pkill -f "port $PORT" 2>/dev/null || true
