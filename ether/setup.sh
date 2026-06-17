#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
echo "=== apt deps $(date +%H:%M:%S) ==="
apt-get update -qq && apt-get install -y -qq git cmake build-essential libgomp1 libcurl4-openssl-dev curl
echo "=== clone+build llama.cpp (native AVX2, -j4) $(date +%H:%M:%S) ==="
cd /opt && rm -rf llama && git clone --depth 1 https://github.com/ggml-org/llama.cpp.git llama
cd llama
cmake -B build -DGGML_NATIVE=ON -DGGML_OPENMP=ON -DCMAKE_BUILD_TYPE=Release >/tmp/cmake.log 2>&1
cmake --build build --config Release -j4 --target llama-server llama-cli llama-bench >/tmp/build.log 2>&1
echo "=== download Granite-3B-Q4 (~2GB) $(date +%H:%M:%S) ==="
mkdir -p /models
curl -fsL https://huggingface.co/ibm-granite/granite-4.1-3b-GGUF/resolve/main/granite-4.1-3b-Q4_K_M.gguf -o /models/granite-3b.gguf
ls -la /models/
echo "=== SETUP-DONE $(date +%H:%M:%S) ==="
