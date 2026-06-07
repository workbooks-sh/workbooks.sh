#!/usr/bin/env bash
# Push every secret in apps/api/.dev.vars to the deployed Worker via `wrangler secret bulk`.
# Run from anywhere; the script cd's to the api workspace.
#
# Usage:
#   bash apps/api/scripts/secrets-push.sh            # default env
#   bash apps/api/scripts/secrets-push.sh production # named env
#
# Prereq: .dev.vars exists (copy .dev.vars.example) and wrangler is authenticated.
set -euo pipefail

API_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$API_DIR"

ENV_ARG=()
if [[ $# -ge 1 ]]; then
  ENV_ARG=(--env "$1")
fi

if [[ ! -f .dev.vars ]]; then
  echo "error: apps/api/.dev.vars not found. Copy .dev.vars.example and fill it in." >&2
  exit 1
fi

TMP_JSON="$(mktemp -t brandnana-secrets.XXXXXX.json)"
trap 'rm -f "$TMP_JSON"' EXIT

# Convert KEY="value" pairs to JSON. Skips blank lines, comments, and empty values.
python3 - "$TMP_JSON" <<'PY'
import json, os, re, sys

out = {}
path = ".dev.vars"
with open(path, "r", encoding="utf-8") as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r'^([A-Z][A-Z0-9_]*)=(.*)$', line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
            val = val[1:-1]
        if val == "":
            continue
        out[key] = val

if not out:
    print("error: no non-empty secrets found in .dev.vars", file=sys.stderr)
    sys.exit(2)

with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(out, f)

print(f"prepared {len(out)} secret(s): {', '.join(sorted(out))}", file=sys.stderr)
PY

bunx wrangler secret bulk "$TMP_JSON" "${ENV_ARG[@]}"
echo "✓ secrets pushed"
