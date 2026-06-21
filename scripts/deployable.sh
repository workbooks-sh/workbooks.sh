#!/usr/bin/env bash
# deployable.sh — "is main safe to deploy to wb-dogfood right now?"
#
# The single source of truth an agent should consult BEFORE deploying (instead of running `fly deploy`
# from a laptop and discovering a release-only boot crash by outaging prod). Reads the latest
# `dogfood-deploy` workflow run on main — that pipeline builds the real release image and boots it
# behind GET /health. Green ⇒ main is deploy-clean (and CI already auto-deployed it). Red ⇒ blocked,
# do NOT deploy; the printed commit + run URL point at what to fix (see bd wb-o5ng for the current one).
#
# Usage:  ./scripts/deployable.sh            # human-readable verdict
#         ./scripts/deployable.sh --quiet    # no output; exit 0 (deployable) / 1 (blocked|building|unknown)
# Requires: gh (authed).

set -euo pipefail
quiet=${1:-}

run_json=$(gh run list --workflow=dogfood-deploy.yml --branch=main -L 1 \
  --json status,conclusion,headSha,displayTitle,url 2>/dev/null || true)

verdict=$(printf '%s' "$run_json" | python3 - <<'PY'
import sys, json
try:
    runs = json.load(sys.stdin)
except Exception:
    runs = []
if not runs:
    print("1\t❓ unknown — no dogfood-deploy run found on main yet")
    sys.exit(0)
r = runs[0]
status = r.get("status"); concl = r.get("conclusion") or "-"
sha = (r.get("headSha") or "")[:8]; url = r.get("url", ""); title = r.get("displayTitle", "")
if status == "completed" and concl == "success":
    print(f"0\t✅ deployable — main is green (build + /health smoke passed); CI deployed {sha}. {url}")
elif status == "completed":
    print(f"1\t🚫 BLOCKED — last dogfood-deploy on main is {concl} at {sha}: \"{title}\". Do NOT deploy; fix first → {url}")
else:
    print(f"1\t⏳ building — dogfood-deploy is {status} for {sha}; wait for green. {url}")
PY
)

code=${verdict%%$'\t'*}
msg=${verdict#*$'\t'}
[ "$quiet" = "--quiet" ] || echo "$msg"
exit "$code"
