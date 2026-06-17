#!/bin/sh
# Runs on every microVM boot. Times the realistic per-invocation cold path:
# (VM already booted to here) -> model load -> prefill -> first tokens.
# Fresh boot = empty page cache = COLD load from the image-baked gguf.
M=/models/granite-4.1-3b-Q4_K_M.gguf
B=/opt/llama/build/bin/llama-cli
LOG=/tmp/coldstart.log
{
  echo "=== boot $(date -u +%H:%M:%S.%3N) ==="
  T0=$(date +%s.%N)
  # mmap default (lazy page-in = realistic fast-TTFT path); -st single-turn; -n 16 for a gen-rate too
  $B -m "$M" -p "Write one sentence about the ocean." -n 16 -t 4 -c 512 -st --no-warmup \
     --no-display-prompt </dev/null >/tmp/g.out 2>/tmp/g.err
  T1=$(date +%s.%N)
  echo "entry->generation-complete wall = $(echo "$T1 - $T0" | bc) s"
  echo "--- llama.cpp timing breakdown (load=cold page-in, prompt eval=prefill, eval=gen) ---"
  grep -iE "load time|prompt eval time|^.* eval time|tokens per second" /tmp/g.err
  echo "--- sample output ---"; tr '\n' ' ' </tmp/g.out | head -c 160
  echo; echo "=== COLDSTART-DONE ==="
} >> "$LOG" 2>&1
cat "$LOG"
sleep infinity
