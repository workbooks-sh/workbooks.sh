#!/usr/bin/env bash
# `wb forge web deploy --to cloudflare` runs this. Publishes a built workbook
# (a single-file <slug>.html, or a directory of static assets) to Cloudflare
# Pages on the USER'S OWN account. We stage the artifact into a clean deploy
# dir (a lone .html becomes index.html so the project root serves it), then
# hand off to `wrangler pages deploy`. The token is wrangler's own — never ours.
#
# Env contract (set by `wb forge web`):
#   WB_FORGE_ARTIFACT   path to the built .html OR a directory   (required)
#   WB_FORGE_PROJECT    Cloudflare Pages project name (slug)     (required)
#   WB_FORGE_BRANCH     deploy branch (default: main)
#   CLOUDFLARE_ACCOUNT_ID  auto-derived from `wrangler whoami` when the login
#                          has exactly one account; required when the login has
#                          >1 account (wrangler can't pick one non-interactively)
#
# This file also defines the shared `wb_cf_resolve_account` resolver, sourced by
# cf-d1.sh (same dir) so both web + app deploys pick the account identically.
set -euo pipefail

# Shared Cloudflare account resolver. When CLOUDFLARE_ACCOUNT_ID is unset, parse
# `wrangler whoami`: exactly one account → export it; multiple → list + exit
# non-zero with a clear message; zero → leave unset (wrangler uses its default).
# Caller must ensure `wrangler whoami` already succeeds (auth done first).
wb_cf_resolve_account() {
  [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] && return 0
  local who ids count
  who="$(wrangler whoami 2>/dev/null || true)"
  # Account IDs are 32-char hex; collect the unique ones (case-insensitive).
  ids="$(printf '%s\n' "$who" | grep -oiE '[0-9a-f]{32}' | tr 'A-F' 'a-f' | sort -u)"
  count="$(printf '%s\n' "$ids" | grep -c . || true)"
  if [ "$count" -gt 1 ]; then
    echo "multiple Cloudflare accounts on this login — set CLOUDFLARE_ACCOUNT_ID to pick one:" >&2
    printf '%s\n' "$who" | grep -iE "account" >&2
    return 1
  elif [ "$count" -eq 1 ]; then
    CLOUDFLARE_ACCOUNT_ID="$ids"
    export CLOUDFLARE_ACCOUNT_ID
  fi
  return 0
}

# Sourced for the resolver only (e.g. by cf-d1.sh) — don't run the deploy below.
[ "${WB_CF_SOURCE_ONLY:-0}" = "1" ] && return 0

command -v wrangler >/dev/null 2>&1 || {
  echo "wrangler not found — run: wb forge web doctor --to cloudflare --login" >&2
  exit 1
}
# Auto-auth: if not signed in, open the browser sign-in right here so the
# AGENT can do this in one shot (its only tool is bash — it runs this command,
# the browser opens, the user just authenticates; no terminal step for them).
# Set WB_FORGE_NO_AUTOLOGIN=1 to fail instead (CI without an interactive login).
if ! wrangler whoami >/dev/null 2>&1; then
  if [ "${WB_FORGE_NO_AUTOLOGIN:-0}" = "1" ]; then
    echo "not authenticated into Cloudflare (WB_FORGE_NO_AUTOLOGIN=1 set) — run: wrangler login" >&2
    exit 1
  fi
  echo "==> not signed in to Cloudflare — opening the browser to sign in (wrangler login)."
  echo "    This signs into YOUR Cloudflare account; the token stays in ~/.wrangler."
  wrangler login
  wrangler whoami >/dev/null 2>&1 || { echo "login did not complete — aborting." >&2; exit 1; }
fi

artifact="${WB_FORGE_ARTIFACT:?WB_FORGE_ARTIFACT (path to built .html or dir) required}"
project="${WB_FORGE_PROJECT:?WB_FORGE_PROJECT (Pages project name) required}"
branch="${WB_FORGE_BRANCH:-main}"

[ -e "$artifact" ] || { echo "artifact not found: $artifact" >&2; exit 1; }

# Stage into a clean dir so we control exactly what ships. A single file is
# served as the site root (index.html); a directory is copied verbatim.
stage="$(mktemp -d "${TMPDIR:-/tmp}/wb-forge-web.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

if [ -d "$artifact" ]; then
  cp -R "$artifact"/. "$stage"/
  [ -f "$stage/index.html" ] || echo "note: no index.html in artifact dir — Pages will 404 at /" >&2
else
  cp "$artifact" "$stage/index.html"
fi

# Make the deployed page installable (Add to Home Screen → standalone, no Safari
# chrome) on iOS. Idempotent; opt out with WB_FORGE_NO_PWA=1.
if [ "${WB_FORGE_NO_PWA:-0}" != 1 ] && [ -f "$stage/index.html" ] && command -v perl >/dev/null 2>&1 \
   && ! grep -q "wb-forge-pwa" "$stage/index.html"; then
  WB_PWA='<meta name="wb-forge-pwa" content="1"><meta name="apple-mobile-web-app-capable" content="yes"><meta name="mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">' \
  perl -0777 -i -pe 'my $m=$ENV{WB_PWA}; if(/<\/head>/i){s/(<\/head>)/$m\n$1/i}elsif(/<head[^>]*>/i){s/(<head[^>]*>)/$1\n$m/i}' "$stage/index.html" \
    && echo "==> web: added add-to-home-screen (apple-mobile-web-app) meta"
fi

echo "==> Cloudflare Pages: project=$project branch=$branch  ($(basename "$artifact"))"

# Pick the account non-interactively (single → auto; multiple → list + stop).
wb_cf_resolve_account

# `wrangler pages deploy` does NOT auto-create the project non-interactively —
# create it first (idempotent: ignore "already exists").
wrangler pages project create "$project" --production-branch "$branch" >/dev/null 2>&1 \
  || true

# --commit-dirty keeps wrangler from refusing a deploy from a dirty git tree. A
# just-created project isn't always queryable immediately, so retry once after a
# brief pause to ride out that propagation race.
deploy_pages() {
  wrangler pages deploy "$stage" \
    --project-name "$project" \
    --branch "$branch" \
    --commit-dirty=true
}
deploy_pages || { echo "==> first deploy raced project creation — retrying in 3s"; sleep 3; deploy_pages; }
