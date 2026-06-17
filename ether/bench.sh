#!/usr/bin/env bash
# Inference-server profiling for a GGUF model on a Fly CPU microVM (bitnet.cpp or llama.cpp).
# 1) CPU/topology facts  2) single-stream thread sweep  3) concurrency sweep (aggregate tok/s).
# Aggregate tok/s is what sets $/M token, so the concurrency plateau is the real result.
# MODEL=<path> picks the gguf (else first found); arg $1 = per-stream threads for the conc sweep.
set -uo pipefail
cd /opt/bitnet 2>/dev/null || cd "$(dirname "$0")"

GGUF=${MODEL:-$(find . -name '*.gguf' 2>/dev/null | head -1)}
BENCH=$(find . -name 'llama-bench' -type f 2>/dev/null | head -1)
CLI=$(find . -name 'llama-cli' -type f 2>/dev/null | head -1)
echo "model=$GGUF"; echo "bench=$BENCH"; echo "cli=$CLI"
[ -z "$GGUF" ] && { echo "FATAL: no gguf"; exit 1; }

# Cap context: llama defaults to the model's trained ctx (32K-512K here), whose KV cache (5GB+
# for the 10B) blows past RAM and thrashes the mmap'd weights. The bench needs almost none.
CTX=${CTX:-2048}

# Disable interactive conversation mode where supported (mainline llama.cpp defaults instruct
# models into a `>` REPL that ignores -n and floods output). Set CNV_FLAG=-no-cnv when launching
# against a mainline build; leave empty for the older bitnet.cpp fork (which has no such flag).
CNV="${CNV_FLAG:-}"
echo "conv-flag=[$CNV]"

echo; echo "=== load smoke-test (Mamba/hybrid kernel gate) ==="
if ! timeout 150 "$CLI" -m "$GGUF" -p "Say hi." -n 8 -t 4 -c 512 $CNV --no-warmup --no-display-prompt </dev/null 2>/tmp/load.err; then
  echo "FATAL: model failed to load/generate (or timed out) on this llama.cpp build:"; tail -20 /tmp/load.err; exit 2
fi
echo "load OK"

echo; echo "=== CPU / topology ==="
lscpu | grep -iE 'model name|^cpu\(s\)|thread|core|socket|numa|mhz|cache|flags' | sed 's/  */ /g'
echo "--- avx check ---"; grep -oE 'avx2|avx512[a-z]*|avx_vnni' /proc/cpuinfo | sort -u | tr '\n' ' '; echo
echo "--- mem ---"; grep -E 'MemTotal' /proc/meminfo

NCPU=$(nproc)
echo; echo "=== single-stream thread sweep (pp512 prefill / tg128 gen) ==="
THREADS=$(for t in 1 2 4 8 16; do [ "$t" -le "$NCPU" ] && printf "%s," "$t"; done | sed 's/,$//')
timeout 400 "$BENCH" -m "$GGUF" -p 512 -n 128 -t "$THREADS" 2>/dev/null || echo "(thread sweep timed out/failed)"

# concurrency sweep: N independent streams at the per-stream thread sweet spot.
# aggregate tok/s = (N * GEN_N) / wall_seconds  -> the number that divides into box $/sec.
GEN_N=128
sweet=${1:-$NCPU}          # per-stream threads (pass best from sweep above)
echo; echo "=== concurrency sweep @ ${sweet} threads/stream, $GEN_N gen tokens/stream ==="
for N in 1 2 3 4 6 8; do
  echo "  [streams=$N] launching $N x $GEN_N tokens @ ${sweet}t ... ($(date +%H:%M:%S))"
  start=$(date +%s.%N)
  pids=()
  for i in $(seq 1 "$N"); do
    timeout 240 "$CLI" -m "$GGUF" -p "Explain quantization in one paragraph." -n "$GEN_N" -t "$sweet" \
       -c "$CTX" $CNV --no-warmup --no-display-prompt </dev/null 2>/dev/null >/tmp/out_$i.txt &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  end=$(date +%s.%N)
  wall=$(echo "$end - $start" | bc)
  agg=$(echo "scale=2; ($N * $GEN_N) / $wall" | bc)
  per=$(echo "scale=2; $agg / $N" | bc)
  printf "streams=%-2d wall=%6.2fs  aggregate=%7s tok/s  per-stream=%6s tok/s\n" "$N" "$wall" "$agg" "$per"
done
echo; echo "DONE. Feed peak aggregate tok/s into cost.py for \$/M."
