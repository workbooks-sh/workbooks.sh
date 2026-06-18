#!/bin/sh
M=/models/granite-4.1-3b-Q4_K_M.gguf
echo "=== drop page cache ==="; sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && echo "dropped" || echo "(no perm to drop)"
free -m | head -2
echo "=== COLD sequential read of 2GB model from image block device ==="
T0=$(date +%s.%N); cat "$M" > /dev/null; T1=$(date +%s.%N)
DUR=$(echo "$T1-$T0"|bc); echo "cold-read = ${DUR}s  ($(echo "scale=1;2002/$DUR"|bc) MB/s)"
echo "=== WARM load+gen (model now cached) ==="
B=/opt/llama/build/bin/llama-cli
T2=$(date +%s.%N); $B -m "$M" -p "Write one sentence about the sea." -n 32 -t 4 -c 512 -st --no-warmup --no-display-prompt </dev/null >/tmp/w.out 2>/tmp/w.err; T3=$(date +%s.%N)
echo "warm load+gen32 = $(echo "$T3-$T2"|bc)s"
grep -iE 'load time|prompt eval|eval time|per second' /tmp/w.err | head
