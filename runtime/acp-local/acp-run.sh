#!/usr/bin/env bash
# Local microVM ACP orchestrator (EXPERIMENTAL — wb-xiei.8). Host-side.
#
# Boots a krunvm microVM running a REAL agent CLI (Codex / Claude Code) against a
# mounted worktree, using the user's OWN subscription auth. LOCAL ONLY. Eventually
# this logic moves into the Tauri desktop layer; for now it's the spike harness.
#
# PROVEN 2026-06-15 (codex): Linux aarch64 microVM, worktree mounted, network egress,
# `codex login status` -> "Logged in using ChatGPT" from the mounted auth, and
# `codex exec` round-tripped gpt-5.5 in ~8s. See README.md.
set -euo pipefail

[ "${WB_ACP_EXPERIMENTAL:-}" = "1" ] || { echo "refusing: set WB_ACP_EXPERIMENTAL=1 (experimental, v2)" >&2; exit 3; }

AGENT="${1:?usage: acp-run.sh <codex|claude> <worktree-dir> <task...>}"
WORKTREE="$(cd "${2:?worktree dir}" && pwd)"
shift 2
TASK="$*"; [ -n "$TASK" ] || { echo "empty task" >&2; exit 2; }

VM="wb-acp-$AGENT-$$"
KRUN="$(command -v krunvm)" || { echo "krunvm not installed" >&2; exit 4; }
# Prebuilt image (fast: agents pre-installed) if it exists in containers-storage;
# else the node base (agents installed inside the VM on first boot — works without
# Docker/colima, which mac buildah needs and can't do for RUN steps).
PREBUILT="${WB_ACP_IMAGE:-localhost/wb-acp-agent:latest}"
BASE="docker.io/library/node:22-bookworm-slim"
IMAGE="$BASE"; buildah images 2>/dev/null | grep -q "${PREBUILT%:*}" && IMAGE="$PREBUILT"

# GOTCHA 1: scrub to an ASCII env — a non-ASCII host env var panics libkrun's
# kernel-cmdline builder (InvalidAscii).
run_krun() { env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" LANG=C LC_ALL=C "$KRUN" "$@"; }

# Throwaway auth dir — we NEVER rw-mount the user's real ~/.codex / ~/.claude (the
# agent writes cache/history; keep that out of the real config). Copy only what's
# needed. krunvm GOTCHA 2: guest mount paths must be a direct child of / (no nesting),
# so auth lands at /agentauth and we point the agent's *_HOME at it.
AUTHTMP="$(mktemp -d)"
CTRL="$WORKTREE/.acp"; mkdir -p "$CTRL"; : > "$CTRL/out.log"
trap 'run_krun delete "$VM" >/dev/null 2>&1 || true; rm -rf "$AUTHTMP" "$CTRL"' EXIT

case "$AGENT" in
  codex)
    [ -f "$HOME/.codex/auth.json" ] || { echo "no ~/.codex/auth.json — run 'codex login' on the host first" >&2; exit 5; }
    cp "$HOME/.codex/auth.json" "$AUTHTMP/"; [ -f "$HOME/.codex/config.toml" ] && cp "$HOME/.codex/config.toml" "$AUTHTMP/"
    # GOTCHA 3: hand the guest its task + script via the volume (not quoted -- args).
    cat > "$CTRL/run.sh" <<'GUEST'
exec > /work/.acp/out.log 2>&1
export HOME=/root CODEX_HOME=/agentauth
# First boot on the bare node base: install ca-certificates (TLS to the model API
# fails without them), git (repo ops), and the agent. No-op on the prebuilt image.
if ! command -v codex >/dev/null; then
  apt-get update -qq && apt-get install -y -qq ca-certificates git >/dev/null 2>&1
  npm i -g @openai/codex >/dev/null 2>&1
fi
echo "[acp] $(codex --version) | $(codex login status 2>&1)"
cd /work
codex exec --sandbox "$(cat /work/.acp/sandbox)" --skip-git-repo-check "$(cat /work/.acp/task.txt)" </dev/null
GUEST
    ;;
  claude)
    # Claude Code's subscription token lives in the macOS Keychain (no file), so
    # bridge it into a guest credentials file. NOTE: unproven end-to-end (codex is
    # the proven path); the credential location inside the guest may need tuning.
    tok="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)" \
      || { echo "no Claude Code keychain credential — sign in with 'claude' on the host first" >&2; exit 5; }
    printf '%s' "$tok" > "$AUTHTMP/.credentials.json"; chmod 600 "$AUTHTMP/.credentials.json"
    cat > "$CTRL/run.sh" <<'GUEST'
exec > /work/.acp/out.log 2>&1
export HOME=/root CLAUDE_CONFIG_DIR=/agentauth
if ! command -v claude >/dev/null; then
  apt-get update -qq && apt-get install -y -qq ca-certificates git >/dev/null 2>&1
  npm i -g @anthropic-ai/claude-code >/dev/null 2>&1
fi
echo "[acp] claude $(claude --version 2>&1)"
cd /work
claude -p "$(cat /work/.acp/task.txt)" --output-format text </dev/null
GUEST
    ;;
  *) echo "unknown agent '$AGENT' (codex|claude)" >&2; exit 2;;
esac
printf '%s' "$TASK" > "$CTRL/task.txt"
# Sandbox mode passed via the volume (krunvm does not forward host env to the guest).
# Default danger-full-access: the microVM IS the isolation boundary (throwaway kernel,
# only the worktree + auth mounted), so the agent's OWN inner sandbox (bubblewrap) is
# redundant AND fights the virtiofs mount (bwrap over /work -> permission denied). Let
# the agent run freely inside the VM, which fully contains it.
printf '%s' "${WB_ACP_SANDBOX:-danger-full-access}" > "$CTRL/sandbox"

run_krun create "$IMAGE" --name "$VM" --cpus "${WB_ACP_CPUS:-4}" --mem "${WB_ACP_MEM:-4096}" \
  --volume "$WORKTREE:/work" --volume "$AUTHTMP:/agentauth" >/dev/null

echo "── $AGENT in microVM ($IMAGE) on $WORKTREE ──"
run_krun start "$VM" -- /bin/sh /work/.acp/run.sh
cat "$CTRL/out.log" 2>/dev/null
