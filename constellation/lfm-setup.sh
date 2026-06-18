#!/usr/bin/env bash
# Provision the LFM2 vs Qwen coding bench on a fresh Vultr Genoa box.
# Builds llama.cpp (CPU, native AVX-512), pulls the candidate GGUFs.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
exec > >(tee -a /root/setup.log) 2>&1
echo "=== $(date) setup start ==="

apt-get update -y
apt-get install -y build-essential cmake git curl libcurl4-openssl-dev ccache python3 bc

# --- llama.cpp (latest, has LFM2 ShortConv + LFM2-24B-A2B day-zero support) ---
cd /opt
if [ ! -d llama.cpp ]; then git clone --depth 1 https://github.com/ggml-org/llama.cpp; fi
cd llama.cpp
cmake -B build -DGGML_NATIVE=ON -DLLAMA_CURL=ON -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build -j"$(nproc)" --target llama-bench llama-cli llama-server
echo "=== build done ==="
ls -la build/bin/ | grep -E 'llama-(bench|cli|server)'

# --- models ---
cd /opt/llama.cpp
mkdir -p models
dl() { # url file
  if [ -s "models/$2" ]; then echo "have $2"; else
    echo "fetch $2"; curl -fL --retry 3 "$1" -o "models/$2.part" && mv "models/$2.part" "models/$2"
  fi
}
# LFM2 coding candidates (MoE-weighted; active params drive bandwidth-bound decode)
dl https://huggingface.co/LiquidAI/LFM2-24B-A2B-GGUF/resolve/main/LFM2-24B-A2B-Q4_K_M.gguf      lfm2-24b-a2b-Q4_K_M.gguf
dl https://huggingface.co/LiquidAI/LFM2.5-8B-A1B-GGUF/resolve/main/LFM2.5-8B-A1B-Q4_K_M.gguf     lfm2.5-8b-a1b-Q4_K_M.gguf
dl https://huggingface.co/LiquidAI/LFM2-2.6B-GGUF/resolve/main/LFM2-2.6B-Q4_K_M.gguf             lfm2-2.6b-Q4_K_M.gguf
# Anchor: our prior shootout winner, same box, live side-by-side
dl https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf qwen3-coder-30b-a3b-Q4_K_M.gguf

echo "=== models on disk ==="
ls -la models/
echo "=== $(date) setup done ==="
