#!/usr/bin/env bash
# Run a REAL Nexus agent with its brain = the local Constellation Granite 8B.
# Proves the full agent architecture (Llm -> local model, bash tool-calling, wasm kit sandbox, VFS,
# telemetry) runs entirely on-device — no OpenRouter, no API key.
#
#   ./run-local-agent.sh ["your task"]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GGUF="$HERE/spike/models/granite-4.1-8b-Q5_K_M.gguf"
PORT=8103
TASK="${1:-Sort the lines in /work/data.txt and tell me how many UNIQUE lines there are. Reply with just the number.}"

# 1. serve the 8B locally (GGUF bakes in Granite's chat + tool template; --jinja enables tool-calling)
if ! curl -s "localhost:$PORT/health" 2>/dev/null | grep -q ok; then
  echo "[serve] starting llama-server (8B Q5, CPU, tools)…"
  nohup llama-server -m "$GGUF" -ngl 0 --port "$PORT" --jinja -c 4096 > /tmp/llama8b.log 2>&1 &
  for _ in $(seq 1 40); do curl -s "localhost:$PORT/health" 2>/dev/null | grep -q ok && break; sleep 3; done
fi
echo "[serve] local Constellation 8B up on :$PORT"

# 2. run the real Nexus agent against it
cat > /tmp/run_agent.exs <<EXS
res = Nexus.Agent.run(
  task: System.get_env("CONSTELLATION_TASK"),
  system: "You are a terse, capable agent.",
  seed: %{"data.txt" => "pear\napple\npear\nfig\napple\nplum\nfig\n"},
  base_url: "http://127.0.0.1:$PORT/v1/chat/completions",
  model: "granite-4.1-8b-Q5_K_M.gguf",
  timeout_ms: 600_000
)
IO.puts("\n===== NEXUS AGENT RESULT (brain = local Constellation 8B) =====")
IO.inspect(res, pretty: true, limit: :infinity)
EXS
cd "$HERE/../nexus" && CONSTELLATION_TASK="$TASK" mix run /tmp/run_agent.exs
