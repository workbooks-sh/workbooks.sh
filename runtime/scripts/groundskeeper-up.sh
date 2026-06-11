#!/usr/bin/env bash
# groundskeeper-up — boot the voice-agent bridge on this box and expose it.
#
# The bridge must run WHERE the repo + bd live (repo_state/file_issue shell
# out to them), i.e. the dev box — so public exposure is a tunnel, not a
# cloud deploy. Uses a cloudflared QUICK tunnel (ephemeral URL, zero account
# setup); re-provision the agent (step printed below) whenever the URL
# changes, or set up a named tunnel for a stable hostname.
#
# Usage:  WB_GK_SECRET=… [ELEVENLABS_API_KEY=…] runtime/scripts/groundskeeper-up.sh
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(git rev-parse --show-toplevel)"

: "${WB_GK_SECRET:?set WB_GK_SECRET (the bridge credential the agent tools present)}"
PORT="${PORT:-4000}"
export WB_WEB=1 WB_GK_SECRET PORT
export WB_GK_HOME="${WB_GK_HOME:-$REPO_ROOT/examples/groundwork}"

echo "groundskeeper bridge: :$PORT  home: $WB_GK_HOME"

# 1. the runtime (control plane + /gk bridge)
mix run --no-halt &
RUNTIME_PID=$!
trap 'kill $RUNTIME_PID 2>/dev/null || true' EXIT

until curl -sf -m 2 "http://localhost:$PORT/health" >/dev/null; do sleep 1; done
echo "bridge up — smoke:"
curl -s -X POST "http://localhost:$PORT/gk/tool/tasks" -H "x-gk-secret: $WB_GK_SECRET" -d '{}'
echo

# 2. the tunnel (prints the public https URL; leave both running)
cat <<'INSTRUCTIONS'
starting cloudflared quick tunnel — once the URL prints, provision with:
  ELEVENLABS_API_KEY=<convai-enabled key> WB_GK_SECRET=<same secret> \
    mix run --no-start -e 'Workbooks.Groundskeeper.ElevenLabs.upsert_agent("https://<tunnel-host>")'
then talk to the agent from the ElevenLabs app / call link.
INSTRUCTIONS
exec cloudflared tunnel --url "http://localhost:$PORT"
