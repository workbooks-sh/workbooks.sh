#!/bin/sh
echo "=== CPU/MEM ==="; nproc; grep -m1 'model name' /proc/cpuinfo; free -m
M=/models/granite-4.1-3b-Q4_K_M.gguf
B=/opt/llama/build/bin/llama-cli
ls -la "$M"
echo "=== run with --no-mmap (load time = full 2GB read), -n 16, capture timings ==="
T0=$(date +%s)
$B -m "$M" -p "Say one sentence." -n 16 -t 4 -c 512 -st --no-warmup --no-mmap --no-display-prompt </dev/null >/tmp/d.out 2>/tmp/d.err
T1=$(date +%s)
echo "wall=$((T1-T0))s"
echo "--- timings ---"; grep -iE 'load time|prompt eval|eval time|sampling|per second' /tmp/d.err | head
echo "--- any error/abort? ---"; grep -iE 'error|abort|killed|oom|warn|failed' /tmp/d.err | head
echo "--- mem after ---"; free -m | head -2
