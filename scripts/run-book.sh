#!/usr/bin/env bash
# run-book.sh — end-to-end Brandnana book run + acceptance gates (wb-syjo).
#
# The §4 acceptance test (BRANDBOOK-STATUS) made runnable + parameterized, with
# the deck-v2 observability the loop built. Dispatches a REAL agent run through
# POST /v1/agent, polls to completion, then runs the deterministic gates on the
# served book and points at the trace.
#
# Usage:
#   BRANDNANA_API_KEY=... ./run-book.sh [domain]      # default: tecovas.com
#   API_BASE=https://api.brandnana.net ./run-book.sh aesop.com
#
# Requires: curl, jq, and (for the round-trip gate) the `wb` CLI on PATH.
# Needs network + a valid key — it talks to the live API. Safe to dry-read with
# `bash -n run-book.sh`.
set -euo pipefail

DOMAIN="${1:-tecovas.com}"
API_BASE="${API_BASE:-https://api.brandnana.net}"
POLL_TIMEOUT_S="${POLL_TIMEOUT_S:-1200}"   # 20 min — 42-section composes are slow
POLL_INTERVAL_S="${POLL_INTERVAL_S:-10}"

say() { printf '\033[1m[run-book]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[run-book] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ── 0. Preflight ──────────────────────────────────────────────────────────────
command -v curl >/dev/null || die "curl not found"
command -v jq   >/dev/null || die "jq not found"
[ -n "${BRANDNANA_API_KEY:-}" ] || die "BRANDNANA_API_KEY unset (Bearer for $API_BASE)"
HAVE_WB=1; command -v wb >/dev/null || { HAVE_WB=0; say "note: wb CLI absent — skipping the unbundle/query gates"; }

WD="$(mktemp -d)"; say "domain=$DOMAIN  api=$API_BASE  workdir=$WD"

# ── 1. Dispatch the real agent run (plan sync, execute async) ──────────────────
say "dispatching POST /v1/agent …"
DISPATCH="$(curl -fsS -X POST "$API_BASE/v1/agent" \
  -H "Authorization: Bearer $BRANDNANA_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc --arg q "brand book for $DOMAIN" '{query:$q}')")" \
  || die "dispatch failed (auth? engine reachable?)"

STATUS_URL="$(echo "$DISPATCH" | jq -r '.status_url // empty')"
WORKBOOK_URL="$(echo "$DISPATCH" | jq -r '.workbook_url // empty')"
[ -n "$STATUS_URL" ] || die "no status_url in dispatch response: $DISPATCH"
say "status_url=$STATUS_URL"

# ── 2. Poll to completion ─────────────────────────────────────────────────────
say "polling (timeout ${POLL_TIMEOUT_S}s) …"
deadline=$(( $(date +%s) + POLL_TIMEOUT_S ))
status="pending"
while :; do
  resp="$(curl -fsS "$STATUS_URL" -H "Authorization: Bearer $BRANDNANA_API_KEY" 2>/dev/null || echo '{}')"
  status="$(echo "$resp" | jq -r '.status // "pending"')"
  case "$status" in
    done)   say "run DONE — cost=\$$(echo "$resp" | jq -r '.total_cost_usd // "?"')  latency=$(echo "$resp" | jq -r '.total_latency_ms // "?"')ms"; break ;;
    failed) die "run FAILED: $(echo "$resp" | jq -r '.error // "unknown"')" ;;
  esac
  [ "$(date +%s)" -lt "$deadline" ] || die "poll timeout after ${POLL_TIMEOUT_S}s (last status: $status)"
  sleep "$POLL_INTERVAL_S"
done
WORKBOOK_URL="$(echo "$resp" | jq -r ".workbook_url // \"$WORKBOOK_URL\"")"

# ── 3. Fetch the served book (must be 200 + text/html) ────────────────────────
say "fetching $WORKBOOK_URL …"
code="$(curl -fsS -o "$WD/served.html" -w '%{http_code}' "$WORKBOOK_URL")"
[ "$code" = "200" ] || die "served book HTTP $code"
grep -q '<script id="wb-source-bundle"' "$WD/served.html" || die "served book missing wb-source-bundle"
say "served OK ($(wc -c < "$WD/served.html") bytes, bundle present)"

# ── 4. Round-trip + data-driven gates (wb) ────────────────────────────────────
if [ "$HAVE_WB" = "1" ]; then
  rm -rf "$WD/unbundle"
  wb unbundle "$WD/served.html" "$WD/unbundle" || die "wb unbundle failed"
  test -f "$WD/unbundle/brand.org" || die "substrate (brand.org) did not ride into the bundle"
  ls "$WD"/unbundle/analysis/*.org >/dev/null 2>&1 || die "analysis/*.org did not ride into the bundle"
  say "round-trip OK — substrate + analysis rode in"

  say "querying the published book for grounded voice insights …"
  wb workbook query "$WD/served.html" '(and (tags insight) (title voice))' \
    || say "note: query returned non-zero (no voice insight or OQL shape)"
fi

# ── 5. Observability pointer ──────────────────────────────────────────────────
say "DONE. To watch the run: wb sessions   then   wb trace <session-id> --follow"
say "served book: $WORKBOOK_URL"
say "workdir (artifacts): $WD"
