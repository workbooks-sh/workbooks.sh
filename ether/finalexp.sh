#!/bin/bash
M=/models/granite-3b.gguf; B=/opt/llama/build/bin/llama-server
[ -s /models/granite-350m-draft.gguf ] || curl -fsL https://huggingface.co/unsloth/granite-4.0-350m-GGUF/resolve/main/granite-4.0-350m-Q4_K_M.gguf -o /models/granite-350m-draft.gguf
cat > /tmp/p.json <<'JSON'
{"prompt":"Write a Lit web component wb-todo-list with add/remove/toggle methods, imports, class, render, and CSS. Return only JavaScript.","n_predict":200,"cache_prompt":false,"temperature":0.2}
JSON
spec() {
  pkill -f llama-server 2>/dev/null; sleep 2
  setsid $B $2 -m $M --host 127.0.0.1 --port 8080 -t 4 -c 4096 --no-warmup >/tmp/srv.log 2>&1 </dev/null &
  for i in $(seq 1 90); do curl -sf localhost:8080/health >/dev/null 2>&1 && break; sleep 1; done
  printf '  %-20s ' "$1"; curl -s localhost:8080/completion --data @/tmp/p.json | python3 -c "import sys,json;t=json.load(sys.stdin).get('timings',{});print('gen %.1f t/s | TTFT %.0fms'%(t.get('predicted_per_second',0),t.get('prompt_ms',0)))" 2>/dev/null || echo "FAILED ($(grep -iE 'error|unknown' /tmp/srv.log|head -1))"
}
echo "=== decode-speed: spec types ==="
spec "baseline"      ""
spec "draft-350m"    "-md /models/granite-350m-draft.gguf --spec-type draft-simple --spec-draft-n-max 4"
spec "ngram-simple"  "--spec-type ngram-simple"
python3 -c "
pre='You are an expert Workbooks author. '+('Workbooks are single-file HTML apps built from Lit wb-* web components and org-mode documents. '*60)
import json
open('/tmp/a.json','w').write(json.dumps({'prompt':pre+'Now write wb-counter.','n_predict':16,'cache_prompt':True}))
open('/tmp/b.json','w').write(json.dumps({'prompt':pre+'Now write wb-toggle.','n_predict':16,'cache_prompt':True}))
"
pkill -f llama-server 2>/dev/null; sleep 2
setsid $B -m $M --host 127.0.0.1 --port 8080 -t 4 -c 4096 --no-warmup >/tmp/srv.log 2>&1 </dev/null &
for i in $(seq 1 90); do curl -sf localhost:8080/health >/dev/null 2>&1 && break; sleep 1; done
echo "=== prompt-cache TTFT win (same ~900-token DSL preamble) ==="
printf '  req1 cold prefix:   '; curl -s localhost:8080/completion --data @/tmp/a.json | python3 -c "import sys,json;t=json.load(sys.stdin).get('timings',{});print('TTFT %.0fms (%d prompt tok)'%(t.get('prompt_ms',0),t.get('prompt_n',0)))"
printf '  req2 cached prefix: '; curl -s localhost:8080/completion --data @/tmp/b.json | python3 -c "import sys,json;t=json.load(sys.stdin).get('timings',{});print('TTFT %.0fms (%d prompt tok)'%(t.get('prompt_ms',0),t.get('prompt_n',0)))"
pkill -f llama-server 2>/dev/null
