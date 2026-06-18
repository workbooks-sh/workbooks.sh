#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq git cmake build-essential libgomp1 libcurl4-openssl-dev curl
echo "AVX-FLAGS: $(lscpu | grep -oE 'avx512[a-z_]*|avx2|avx_vnni' | sort -u | tr '\n' ' ')"
cd /opt && rm -rf llama && git clone --depth 1 https://github.com/ggml-org/llama.cpp.git llama && cd llama
cmake -B build -DGGML_NATIVE=ON -DGGML_OPENMP=ON -DCMAKE_BUILD_TYPE=Release >/tmp/cmake.log 2>&1
cmake --build build --config Release -j16 --target llama-bench llama-cli llama-server >/tmp/build.log 2>&1
echo "BUILD-DONE $(date +%H:%M:%S)"
mkdir -p /models
curl -fsL https://huggingface.co/ibm-granite/granite-4.1-3b-GGUF/resolve/main/granite-4.1-3b-Q4_K_M.gguf -o /models/granite-3b.gguf
echo "GRANITE-DONE $(date +%H:%M:%S)"
curl -fsL https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf -o /models/qwen3coder-moe.gguf
echo "MOE-DONE $(date +%H:%M:%S)"
echo "SETUP-DONE"
