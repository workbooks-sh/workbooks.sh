#!/usr/bin/env bash
# Sync the capability ledger's authoritative suite total from a REAL test run.
# Runs the deterministic suite, extracts "N tests, M failures", and patches
# runtime/capabilities.json (suite.tests / suite.failures / suite.verified) so the
# /capabilities dashboard headline can't drift from reality. Run after test changes.
#   usage:  bash scripts/sync-capabilities.sh
set -euo pipefail
cd "$(dirname "$0")/.."   # → runtime/

echo "running deterministic suite (this is also the green gate)…"
OUT="$(mix test --seed 0 2>&1 | grep -aE '[0-9]+ tests?, [0-9]+ failures' | tail -1)"
echo "  $OUT"

TESTS="$(printf '%s' "$OUT" | grep -oE '[0-9]+ test' | grep -oE '[0-9]+' | head -1)"
FAILS="$(printf '%s' "$OUT" | grep -oE '[0-9]+ failure' | grep -oE '[0-9]+' | head -1)"
DATE="$(date +%Y-%m-%d)"

if [ -z "${TESTS:-}" ] || [ -z "${FAILS:-}" ]; then
  echo "could not parse test counts — leaving ledger untouched" >&2
  exit 1
fi

TESTS="$TESTS" FAILS="$FAILS" DATE="$DATE" python3 - <<'PY'
import json, os
p = "capabilities.json"
d = json.load(open(p))
d.setdefault("suite", {})
d["suite"]["tests"] = int(os.environ["TESTS"])
d["suite"]["failures"] = int(os.environ["FAILS"])
d["suite"]["verified"] = f"{os.environ['DATE']} (seed 0, 365 heavy-tagged excluded)"
d["updated"] = os.environ["DATE"]
json.dump(d, open(p, "w"), indent=2)
print(f"ledger synced → suite {d['suite']['tests']} tests, {d['suite']['failures']} failures ({os.environ['DATE']})")
PY
