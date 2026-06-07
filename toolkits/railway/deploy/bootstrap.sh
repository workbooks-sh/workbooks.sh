#!/usr/bin/env bash
# `wb deploy apply` (ENGINE_PLACE=railway). Railway sells long-lived containers
# (no machine-per-run API), so sandboxes are in-process only — the CLI coherence
# matrix rejects anything else before this runs. Spine + hook contract:
# deploy-kit/recipe/common.sh + deploy-kit/README.org.
#
# Railway-specific env: RAILWAY_API_TOKEN (required), RAILWAY_PROJECT_ID
# (existing project; created if unset on apply), WB_IMAGE (prebuilt engine
# image, STRONGLY preferred), GHCR_USERNAME/GHCR_TOKEN (private-pull creds).
#
# LIVE-VERIFY: built against Railway's documented CLI + public GraphQL API but
# not yet run against a live Railway account — confirm end-to-end before
# relying on it (PROMISES.org).
set -euo pipefail

command -v railway >/dev/null 2>&1 || {
  echo "railway CLI not found — install from https://docs.railway.com/guides/cli" >&2
  exit 1
}
: "${RAILWAY_API_TOKEN:?set RAILWAY_API_TOKEN in your environment (Railway account/project token)}"
export RAILWAY_API_TOKEN

# shellcheck source=../../../deploy-kit/recipe/common.sh
source "$WB_DEPLOY_KIT/recipe/common.sh"
wb_recipe_init
export WB_RECIPE_PLACE=railway

echo "==> Workbooks Engine → Railway (headless${UPDATE:+, update=$UPDATE}): service=$WB_APP_NAME region=$WB_REGION"
echo "    profile: $WB_PROFILE"

wb_base_secret_args
SECRET_ARGS+=("WB_VMM_BACKEND=process")
# Volume mounts can hit non-root permission errors on Railway → run as uid 0.
SECRET_ARGS+=("RAILWAY_RUN_UID=0")

# shellcheck disable=SC2119  # no provider-extra creds to forward on Railway
wb_append_forward_secrets

# GraphQL for what the CLI can't express (pointing a service at a prebuilt
# registry image is a serviceInstanceUpdate on the service's ID, not its name).
RAILWAY_GQL="https://backboard.railway.com/graphql/v2"
railway_gql() {
  curl -fsS "$RAILWAY_GQL" \
    -H "Authorization: Bearer $RAILWAY_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$(printf '{"query":%s}' "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')")"
}

# Resolve the linked project's service NAMED $WB_APP_NAME to its service ID.
railway_service_id() {
  local pid
  pid="${RAILWAY_PROJECT_ID:-$(railway status --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)}"
  [ -n "$pid" ] || return 1
  railway_gql "query { project(id: \"$pid\") { services { edges { node { id name } } } } }" \
    | python3 -c '
import json, sys, os
edges = json.load(sys.stdin)["data"]["project"]["services"]["edges"]
name = os.environ["WB_APP_NAME"]
sys.stdout.write(next((e["node"]["id"] for e in edges if e["node"]["name"] == name), ""))'
}

provider_ensure_app() {
  if [ -n "${RAILWAY_PROJECT_ID:-}" ]; then
    railway link --project "$RAILWAY_PROJECT_ID" >/dev/null
    echo "    linked existing project $RAILWAY_PROJECT_ID"
  elif [ "$UPDATE" = 1 ]; then
    echo "    update: RAILWAY_PROJECT_ID must be set to converge an existing Railway project" >&2
    exit 1
  else
    railway init --name "$WB_APP_NAME" >/dev/null
    echo "    created Railway project for $WB_APP_NAME"
  fi
  railway service "$WB_APP_NAME" >/dev/null 2>&1 || railway add --service "$WB_APP_NAME" >/dev/null
}

provider_set_secrets() {
  # Railway "variables" ARE the secrets mechanism (injected as env at runtime).
  local kv
  for kv in "${SECRET_ARGS[@]}"; do
    railway variables --service "$WB_APP_NAME" --set "$kv" >/dev/null
  done
  echo "    set ${#SECRET_ARGS[@]} variables on service $WB_APP_NAME"
}

provider_attach_volume() {
  railway volume add --service "$WB_APP_NAME" --mount-path /data >/dev/null 2>&1 \
    && echo "    attached volume at /data" \
    || echo "    volume at /data already present (or attach unsupported on plan)"
}

provider_deploy_image() {
  if [ -n "${WB_IMAGE:-}" ]; then
    local sid
    sid="$(railway_service_id)" || sid=""
    [ -n "$sid" ] || {
      echo "    could not resolve the Railway serviceId for '$WB_APP_NAME' — cannot point it at $WB_IMAGE" >&2
      exit 1
    }
    echo "    deploying prebuilt image via GraphQL source.image: $WB_IMAGE (serviceId $sid)"
    railway_gql "mutation { serviceInstanceUpdate(serviceId: \"$sid\", input: { source: { image: \"$WB_IMAGE\" } }) }" >/dev/null
    railway redeploy --service "$WB_APP_NAME" --yes >/dev/null 2>&1 || true
  else
    echo "    no WB_IMAGE — building on Railway from the Dockerfile (railway up); prefer WB_IMAGE for parity with Fly"
    ( cd "$REPO_ROOT" && railway up --service "$WB_APP_NAME" --detach )
  fi
}

provider_public_url() {
  railway domain --service "$WB_APP_NAME" 2>/dev/null | grep -oE 'https://[^ ]+' | head -1 \
    || echo "https://${WB_APP_NAME}.up.railway.app"
}

wb_recipe_run
