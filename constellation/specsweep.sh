#!/bin/bash
M=/models/granite-3b.gguf; D=/models/granite-1b-draft.gguf; B=/opt/llama/build/bin/llama-server
cat > /tmp/payload.json <<'JSON'
{"prompt":"Write a complete Lit web component named wb-todo-list with add, remove, toggle-complete methods, imports, class, render, and CSS. Return only JavaScript.","n_predict":200,"cache_prompt":false,"temperature":0.2}
JSON
run() {
  pkill -f llama-server 2>/dev/null; sleep 2
  setsid $B $2 -m $M --host 127.0.0.1 --port 8080 -t 4 -c 4096 --no-warmup >/tmp/srv.log 2>&1 </dev/null &
  for i in $(seq 1 90); do curl -sf localhost:8080/health >/dev/null 2>&1 && break; sleep 1; done
  R=$(curl -s localhost:8080/completion -H 'Content-Type: application/json' --data @/tmp/payload.json)
  echo "[$1]"; echo "$R" | python3 -c "
import sys,json; t=json.load(sys.stdin).get('timings',{})
print('  gen %.1f t/s | TTFT %.0fms | fields:' % (t.get('predicted_per_second',0), t.get('prompt_ms',0)), [k for k in t if 'draft' in k or 'accept' in k])
for k in t:
    if 'draft' in k or 'accept' in k: print('   ',k,'=',t[k])
"
}
run "baseline"            ""
run "spec n-max=2"        "-md $D --spec-draft-n-max 2"
run "spec n-max=4"        "-md $D --spec-draft-n-max 4"
run "spec n-max=8 td=2"   "-md $D --spec-draft-n-max 8 --threads-draft 2"
pkill -f llama-server 2>/dev/null
