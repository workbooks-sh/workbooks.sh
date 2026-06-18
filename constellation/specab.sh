#!/bin/bash
M=/models/granite-3b.gguf; B=/opt/llama/build/bin/llama-server
cat > /tmp/payload.json <<'JSON'
{"prompt":"Write a complete Lit web component named wb-todo-list with methods to add, remove, and toggle items complete. Include imports, the class, the render method, and CSS styles. Return only JavaScript.","n_predict":256,"cache_prompt":false,"temperature":0.2}
JSON
run() {
  pkill -f llama-server 2>/dev/null; sleep 2
  setsid $B $2 -m $M --host 127.0.0.1 --port 8080 -t 4 -c 4096 --no-warmup --metrics >/tmp/srv.log 2>&1 </dev/null &
  for i in $(seq 1 90); do curl -sf localhost:8080/health >/dev/null 2>&1 && break; sleep 1; done
  echo "[$1]  (server flags: ${2:-none})"
  curl -s localhost:8080/completion -H 'Content-Type: application/json' --data @/tmp/payload.json | python3 -c "
import sys,json
t=json.load(sys.stdin).get('timings',{})
print('  gen      : %.1f tok/s  (%d tokens, %.1fs)' % (t.get('predicted_per_second',0),t.get('predicted_n',0),t.get('predicted_ms',0)/1000))
print('  TTFT     : %.0f ms' % t.get('prompt_ms',0))
dn=t.get('draft_n'); da=t.get('draft_n_accepted')
if dn: print('  draft    : %s proposed, %s accepted (%.0f%%)' % (dn,da,100*da/dn if dn else 0))
"
  grep -iE 'draft|error|loaded' /tmp/srv.log | grep -iE 'draft|vocab|error' | head -2
}
run "BASELINE" ""
run "SPECULATIVE" "-md /models/granite-1b-draft.gguf --spec-draft-n-max 16"
pkill -f llama-server 2>/dev/null
