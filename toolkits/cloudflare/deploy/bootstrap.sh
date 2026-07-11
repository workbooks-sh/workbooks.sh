#!/usr/bin/env bash
# `work deploy apply` (ENGINE_PLACE=cloudflare) — the EDGE ARTIFACT provider (wb-jr1py.8).
#
# Cloudflare does not run the engine container: Workers/Pages have no OCI runtime and no
# volume, so this recipe deploys the workbook's built EDGE ARTIFACT — a static multi-page
# bundle (+ optional worker shell) to Cloudflare Pages, and optionally syncs generated
# assets into an R2 bucket. The stateful nexus (the agent's home) stays on a container
# provider (fly/railway); this place is where the APPS those agents manage get served,
# egress-free. Spine + hook contract: deploy-kit/recipe/common.sh.
#
# Cloudflare-specific env:
#   WB_SITE_DIR             built static bundle dir (required for `up`)
#   CLOUDFLARE_ACCOUNT_ID   auto-derived from `wrangler whoami` when the login has exactly
#                           one account; required with >1 account
#   WB_R2_BUCKET            optional: R2 bucket to sync WB_ASSET_DIR into
#   WB_ASSET_DIR            optional: local dir of generated assets to push to WB_R2_BUCKET
#   WB_PAGES_BRANCH         deploy branch (default: main)
set -euo pipefail

command -v wrangler >/dev/null 2>&1 || {
  echo "wrangler not found — npm i -g wrangler (or use the wrangler toolkit)" >&2
  exit 1
}
wrangler whoami >/dev/null 2>&1 || {
  echo "not authenticated into Cloudflare — run \`wrangler login\` first (non-interactive deploys need a prior login or CLOUDFLARE_API_TOKEN)" >&2
  exit 1
}

# shellcheck source=../../../cli/deploy-kit/recipe/common.sh
source "$WB_DEPLOY_KIT/recipe/common.sh"
# The spine requires WB_IMAGE (the ONE engine artifact) — cloudflare has no engine image;
# the artifact is WB_SITE_DIR. Satisfy the init check without pretending otherwise.
export WB_IMAGE="${WB_IMAGE:-edge-artifact}"
wb_recipe_init
export WB_RECIPE_PLACE=cloudflare
WB_PAGES_BRANCH="${WB_PAGES_BRANCH:-main}"

# Shared account resolver — canonical copy lives in toolkits/wrangler/deploy/cloudflare.sh
# (wb_cf_resolve_account); inlined here because toolkits are staged independently.
wb_cf_resolve_account() {
  [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ] && return 0
  local who ids count
  who="$(wrangler whoami 2>/dev/null || true)"
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

provider_ensure_app() {
  wb_cf_resolve_account
  # `pages deploy` won't auto-create non-interactively — create first (idempotent).
  wrangler pages project create "$WB_APP_NAME" --production-branch "$WB_PAGES_BRANCH" >/dev/null 2>&1 || true
  echo "    pages project $WB_APP_NAME ready"
}

provider_set_secrets() {
  # Only the deployment.org-declared WB_SECRET_KEYS go to the edge (a Pages Function env).
  # Engine env (WB_DATA/PORT/…) is meaningless here — the engine lives at the origin nexus.
  local k n=0
  for k in ${WB_SECRET_KEYS:-}; do
    [ -n "${!k:-}" ] || continue
    printf '%s' "${!k}" | wrangler pages secret put "$k" --project-name "$WB_APP_NAME" >/dev/null
    n=$((n + 1))
  done
  echo "    set $n edge secret(s) on $WB_APP_NAME"
}

provider_attach_volume() {
  # No volume at the edge — durable bytes belong in R2 (WB_R2_BUCKET), state in the origin
  # nexus. Deliberate no-op so the spine's converge order holds for every provider.
  echo "    no volume on cloudflare (durable bytes → R2, state → origin nexus) — skipped"
}

provider_deploy_image() {
  : "${WB_SITE_DIR:?WB_SITE_DIR not set (the built static bundle dir — cloudflare deploys artifacts, not engine images)}"
  [ -d "$WB_SITE_DIR" ] || { echo "WB_SITE_DIR not a directory: $WB_SITE_DIR" >&2; exit 1; }

  echo "    deploying $WB_SITE_DIR → pages:$WB_APP_NAME ($WB_PAGES_BRANCH)"
  deploy_pages() {
    wrangler pages deploy "$WB_SITE_DIR" \
      --project-name "$WB_APP_NAME" \
      --branch "$WB_PAGES_BRANCH" \
      --commit-dirty=true
  }
  # A just-created project isn't always queryable immediately — retry once.
  deploy_pages || { echo "    first deploy raced project creation — retrying in 3s"; sleep 3; deploy_pages; }

  if [ -n "${WB_R2_BUCKET:-}" ] && [ -n "${WB_ASSET_DIR:-}" ] && [ -d "$WB_ASSET_DIR" ]; then
    wrangler r2 bucket create "$WB_R2_BUCKET" >/dev/null 2>&1 || true
    local f key n=0
    while IFS= read -r -d '' f; do
      key="${f#"$WB_ASSET_DIR"/}"
      wrangler r2 object put "$WB_R2_BUCKET/$key" --file "$f" >/dev/null
      n=$((n + 1))
    done < <(find "$WB_ASSET_DIR" -type f -print0)
    echo "    synced $n asset(s) → r2:$WB_R2_BUCKET"
  fi
}

provider_public_url() {
  echo "https://${WB_APP_NAME}.pages.dev"
}

provider_down() {
  wrangler pages project delete "$WB_APP_NAME" --yes >/dev/null 2>&1 \
    && echo "    pages project $WB_APP_NAME deleted" \
    || echo "    pages project $WB_APP_NAME not found (already down)"
}

provider_status() {
  if wrangler pages project list 2>/dev/null | grep -q "$WB_APP_NAME"; then
    echo "up: pages:$WB_APP_NAME · $(provider_public_url)"
  else
    echo "down: no pages project $WB_APP_NAME"
  fi
}

provider_logs() {
  # Pages has deployment logs, not a live engine tail.
  wrangler pages deployment list --project-name "$WB_APP_NAME" 2>/dev/null \
    || echo "no deployments for $WB_APP_NAME"
}

wb_recipe_run
