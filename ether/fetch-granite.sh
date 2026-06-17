#!/usr/bin/env bash
# Pull both Granite 4.1 Q4_K_M GGUFs onto the machine at runtime.
set -euo pipefail
cd /opt/llama && mkdir -p models
dl() { [ -s "models/$2" ] || curl -fL "$1" -o "models/$2"; }
dl https://huggingface.co/ibm-granite/granite-4.1-3b-GGUF/resolve/main/granite-4.1-3b-Q4_K_M.gguf granite-4.1-3b-Q4_K_M.gguf
dl https://huggingface.co/ibm-granite/granite-4.1-8b-GGUF/resolve/main/granite-4.1-8b-Q4_K_M.gguf granite-4.1-8b-Q4_K_M.gguf
ls -la models
