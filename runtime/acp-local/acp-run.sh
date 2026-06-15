#!/usr/bin/env bash
# Local microVM ACP orchestrator (EXPERIMENTAL — wb-xiei.8). Host-side.
#
# Boots a throwaway krunvm microVM running a REAL agent CLI (Codex / Claude Code)
# against a mounted worktree, using the user's OWN subscription auth. LOCAL ONLY.
# Eventually this logic moves into the Tauri desktop layer; for now it's a spike
# harness that encodes the proven invocation (see README.md).
set -euo pipefail

[ "${WB_ACP_EXPERIMENTAL:-}" = "1" ] || { echo "refusing: set WB_ACP_EXPERIMENTAL=1 (experimental, v2)" >&2; exit 3; }

AGENT="${1:?usage: acp-run.sh <codex|claude> <worktree-dir> <task...>}"
WORKTREE="$(cd "${2:?worktree dir}" && pwd)"
shift 2
TASK="$*"; [ -n "$TASK" ] || { echo "empty task" >&2; exit 2; }

IMAGE="${WB_ACP_IMAGE:-localhost/wb-acp-agent:latest}"
VM="wb-acp-$$"
KRUN="$(command -v krunvm)" || { echo "krunvm not installed" >&2; exit 4; }

# GOTCHA 1: scrub to an ASCII env — a non-ASCII host env var panics libkrun's
# kernel-cmdline builder (InvalidAscii).
run_krun() { env -i HOME="$HOME" PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" LANG=C LC_ALL=C "$KRUN" "$@"; }

# GOTCHA 2: hand the guest its task + run-script through the volume, not via
# quoted `--` args (nested quoting across the VM boundary gets mangled).
CTRL="$WORKTREE/.acp"; mkdir -p "$CTRL"
printf '%s' "$TASK" > "$CTRL/task.txt"

CLEANUP=':'
auth_args=()
case "$AGENT" in
  codex)
    # Codex auth is a plain file — mount it read-only into the guest's HOME.
    [ -f "$HOME/.codex/auth.json" ] || { echo "no ~/.codex/auth.json — run 'codex login' on the host first" >&2; exit 5; }
    auth_args=(--volume "$HOME/.codex:/root/.codex")
    cat > "$CTRL/run.sh" <<'GUEST'
cd /work && codex exec "$(cat /work/.acp/task.txt)" 2>&1
GUEST
    ;;
  claude)
    # Claude Code stores its subscription token in the macOS Keychain (no file),
    # so bridge it: export the token to a temp credentials file, mount that.
    tok="$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null)" \
      || { echo "no Claude Code keychain credential — run 'claude' + sign in on the host first" >&2; exit 5; }
    cdir="$(mktemp -d)"; printf '%s' "$tok" > "$cdir/.credentials.json"; chmod 600 "$cdir/.credentials.json"
    CLEANUP="rm -rf '$cdir'"
    auth_args=(--volume "$cdir:/root/.claude")
    cat > "$CTRL/run.sh" <<'GUEST'
cd /work && claude -p "$(cat /work/.acp/task.txt)" --output-format text 2>&1
GUEST
    ;;
  *) echo "unknown agent '$AGENT' (codex|claude)" >&2; exit 2;;
esac

run_krun delete "$VM" >/dev/null 2>&1 || true
trap 'run_krun delete "$VM" >/dev/null 2>&1 || true; rm -rf "$CTRL"; eval "$CLEANUP"' EXIT

run_krun create "$IMAGE" --name "$VM" --cpus "${WB_ACP_CPUS:-4}" --mem "${WB_ACP_MEM:-4096}" \
  --volume "$WORKTREE:/work" "${auth_args[@]}" >/dev/null

echo "── $AGENT in microVM $VM on $WORKTREE ──"
run_krun start "$VM" -- /bin/sh /work/.acp/run.sh
