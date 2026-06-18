#!/usr/bin/env bash
# Per-model: (1) llama-bench raw speed (pp512/tg128 @12t), (2) serve + run coding prompts,
# capturing each completion + server-reported timings (tok/s, n_tokens) to /root/results.
set -uo pipefail
cd /opt/llama.cpp
BIN=build/bin
BENCH=$BIN/llama-bench
SERVER=$BIN/llama-server
THREADS=12
PORT=8080
RES=/root/results
mkdir -p "$RES"

# model_key : gguf_file
MODELS=(
  "lfm2-24b-a2b:models/lfm2-24b-a2b-Q4_K_M.gguf"
  "lfm2.5-8b-a1b:models/lfm2.5-8b-a1b-Q4_K_M.gguf"
  "lfm2-2.6b:models/lfm2-2.6b-Q4_K_M.gguf"
  "qwen3-coder-30b-a3b:models/qwen3-coder-30b-a3b-Q4_K_M.gguf"
)

wait_health() { for i in $(seq 1 120); do curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }

run_prompts() {
  local key=$1; local out=$RES/$key; mkdir -p "$out"
  local n=0
  while IFS= read -r line; do
    n=$((n+1))
    local pid=$(echo "$line" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    local body=$(echo "$line" | python3 -c "import sys,json;o=json.load(sys.stdin);print(json.dumps({'model':'m','messages':[{'role':'system','content':o['sys']},{'role':'user','content':o['user']}],'temperature':0.2,'max_tokens':1200,'stream':False}))")
    echo "  [$key] prompt $pid"
    curl -s "http://localhost:$PORT/v1/chat/completions" -H 'Content-Type: application/json' -d "$body" > "$out/$pid.json"
    # extract content + timing
    python3 - "$out/$pid.json" "$out/$pid.md" "$out/$pid.stats" <<'PY'
import sys,json
j=json.load(open(sys.argv[1]))
c=j.get('choices',[{}])[0].get('message',{}).get('content','')
open(sys.argv[2],'w').write(c)
u=j.get('usage',{}); t=j.get('timings',{})
open(sys.argv[3],'w').write(json.dumps({'completion_tokens':u.get('completion_tokens'),'prompt_tokens':u.get('prompt_tokens'),'predicted_per_second':t.get('predicted_per_second'),'prompt_per_second':t.get('prompt_per_second')}))
PY
  done < /root/lfm-prompts.jsonl
}

for entry in "${MODELS[@]}"; do
  key=${entry%%:*}; gguf=${entry#*:}
  echo "================ $key ($gguf) ================"
  if [ ! -s "$gguf" ]; then echo "MISSING $gguf — skip"; continue; fi

  echo "--- llama-bench $key ---"
  $BENCH -m "$gguf" -p 512 -n 128 -t $THREADS 2>/dev/null | tee "$RES/$key.bench.txt"

  echo "--- serve $key ---"
  setsid $SERVER -m "$gguf" -t $THREADS -c 8192 --jinja --port $PORT --host 127.0.0.1 \
     >"$RES/$key.server.log" 2>&1 < /dev/null &
  SPID=$!
  if wait_health; then
    run_prompts "$key"
  else
    echo "  HEALTH FAIL for $key"; tail -20 "$RES/$key.server.log"
  fi
  kill "$SPID" 2>/dev/null; pkill -f llama-server 2>/dev/null; sleep 3
done

echo "================ SUMMARY ================"
for entry in "${MODELS[@]}"; do
  key=${entry%%:*}
  bench=$(grep -E 'tg128|tg 128' "$RES/$key.bench.txt" 2>/dev/null | tail -1)
  echo "[$key] $bench"
done
echo "DONE $(date)"
