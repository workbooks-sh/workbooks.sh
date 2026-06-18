#!/usr/bin/env bash
# Full benchmark: Gemma AR baselines vs heterogeneous UAG fusion across block sizes.
# Run once the verifier (mlx/gemma-4-12B-it-qat-4bit) has finished downloading.
set -u
cd "$(dirname "$0")/.."
P="Write a Python function fib(n) that returns the nth Fibonacci number. Return only code."
H="mlx/hetero_fusion_uag.py"

echo "############ ETHER FUSION BENCHMARK ############"
echo "--- baseline: Gemma AR alone on CPU ---"
MODE=baseline BASE_DEV=cpu MAXTOK=96 python3 "$H" "$P" 2>&1 | grep -E "baseline|tok/s" | tail -1
echo "--- baseline: Gemma AR alone on GPU ---"
MODE=baseline BASE_DEV=gpu MAXTOK=96 python3 "$H" "$P" 2>&1 | grep -E "baseline|tok/s" | tail -1
for K in 8 12 16; do
  for DS in 4 8; do
    echo "--- fusion K=$K dsteps=$DS (GPU draft || CPU verify) ---"
    K=$K DSTEPS=$DS MAXTOK=96 python3 "$H" "$P" 2>&1 | grep -E "fusion|accept_rate" | tail -2
  done
done
echo "################################################"
