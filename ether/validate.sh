#!/bin/bash
M=/models/granite-3b.gguf
B=/opt/llama/build/bin
pkill -f llama-server 2>/dev/null; sleep 1
echo "=== start persistent llama-server (warm, stays loaded) ==="
setsid $B/llama-server -m $M --host 127.0.0.1 --port 8080 -t 4 -c 8192 --no-warmup --metrics --jinja >/tmp/server.log 2>&1 </dev/null &
for i in $(seq 1 40); do curl -sf http://127.0.0.1:8080/health >/dev/null 2>&1 && break; sleep 1; done
echo "server up; model RAM footprint:"; ps -o rss= -C llama-server | awk '{printf "%.2f GB\n", $1/1048576}'
echo "=== real codegen prompt (one user) — TTFT + gen tok/s from server timings ==="
curl -s http://127.0.0.1:8080/completion -H 'Content-Type: application/json' -d '{
  "prompt":"Write a minimal Lit web component named wb-counter with an increment button and a live count display. Return only the JavaScript.",
  "n_predict":200,"cache_prompt":false,"temperature":0.2
}' | python3 -c "
import sys,json
d=json.load(sys.stdin); t=d.get('timings',{})
print('TTFT (prompt eval): %.0f ms  (%d prompt tokens @ %.1f t/s)' % (t.get('prompt_ms',0), t.get('prompt_n',0), t.get('prompt_per_second',0)))
print('Generation: %.1f tok/s  (%d tokens in %.1f s)' % (t.get('predicted_per_second',0), t.get('predicted_n',0), t.get('predicted_ms',0)/1000))
print('--- sample output ---'); print(d.get('content','')[:240])
"
echo "=== RAM after one request (model + KV) ==="; free -m | awk 'NR<=2{print}'
