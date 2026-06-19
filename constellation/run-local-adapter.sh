#!/usr/bin/env bash
# Prove a Constellation LoRA adapter (a plug-and-play SKILL) is reachable through the real Nexus
# runtime's LLM seam (Nexus.Llm.complete). Serves a Granite GGUF base + a GGUF LoRA adapter on
# llama-server, then asks — through Nexus.Llm — a question only the adapter knows.
#
#   ./run-local-adapter.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="$HERE/spike/models/granite-4.0-350m-Q4_K_M.gguf"
LORA="$HERE/spike/models/constellation-lora.gguf"   # adapter taught the base 'AURORA-SEVEN'
PORT=8104

if ! curl -s "localhost:$PORT/health" 2>/dev/null | grep -q ok; then
  echo "[serve] llama-server: Granite base + GGUF LoRA adapter…"
  nohup llama-server -m "$BASE" --lora "$LORA" --port "$PORT" -c 2048 > /tmp/llama350lora.log 2>&1 &
  for _ in $(seq 1 30); do curl -s "localhost:$PORT/health" 2>/dev/null | grep -q ok && break; sleep 2; done
fi
echo "[serve] base+adapter up on :$PORT"

cat > /tmp/llm_adapter.exs <<EXS
{:ok, r} = Nexus.Llm.complete(
  [%{role: "user", content: "What is the Constellation access codename?"}],
  base_url: "http://127.0.0.1:$PORT/v1/chat/completions", model: "granite-350m", max_tokens: 40)
IO.puts("\n===== via Nexus.Llm (runtime seam) + local base+adapter =====")
IO.puts(r.content |> to_string() |> String.split("\n") |> hd())
EXS
cd "$HERE/../nexus" && mix run /tmp/llm_adapter.exs
