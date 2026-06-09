#!/usr/bin/env bash
# The provider-neutral recipe spine. Each cloud place is
# cli/deploy-kit/providers/<place>/bootstrap.sh: it sources THIS, fills the five hooks
#   provider_ensure_app / provider_set_secrets / provider_attach_volume /
#   provider_deploy_image / provider_public_url
# plus the lifecycle trio (provider_down / provider_status / provider_logs),
# sets WB_RECIPE_PLACE, and calls `wb_recipe_run`. The deploy-kit invokes the
# bootstrap with WB_RECIPE_ACTION (up|down|status|logs|url|secrets) + the assembled env.
#
# SIMPLIFIED model: one BEAM container, WASM inside — there is NO ephemeral
# sandbox half. A provider implements only the ENGINE contract ("run my container
# + volume + secrets + port"), which ports cleanly to any PaaS / host.
set -euo pipefail

# Required for any action that touches the engine. Image is the ONE artifact.
wb_recipe_init() {
  : "${WB_IMAGE:?WB_IMAGE not set (the runtime OCI image, e.g. ghcr.io/workbooks-sh/runtime:latest)}"
  WB_APP_NAME="${WB_APP_NAME:-workbooks}"
  WB_PORT="${WB_PORT:-4000}"
  WB_DATA="${WB_DATA:-/data}"
}

# The engine env every provider forwards into the container: the deployment.org
# axes (tenancy + BYOD storage/db + profile/region) plus credential VALUES
# forwarded from the deployer's env. `WB_SECRET_KEYS` (space-separated names,
# from deployment.org `#+DEPLOY_SECRETS:` via the kit) extends the forwarded set
# — the kit abstracts secrets; providers just receive the pairs. NOTE: generated
# secrets (WB_SIGNING_KEY / WB_PUBLIC_BEARER) are NOT generated here — they must
# be PERSISTED by the operator (via `wb deploy secrets set`), not rotated on each
# apply (rotation 401s live clients and breaks the tenant DID). The deploy-kit
# auto-generates WB_PUBLIC_BEARER ONCE on first cloud apply and persists it in
# secrets.env; subsequent applies reuse the stored value forwarded here.
wb_base_env() {
  WB_ENGINE_ENV=("WB_WEB=1" "PORT=${WB_PORT}" "WB_DATA=${WB_DATA}" "WB_EMBED=${WB_EMBED:-local}")
  local k
  for k in WB_TENANCY_MODE WB_PROFILE_DIR WB_REGION WB_TENANT \
           WB_PUBLIC_BEARER \
           WB_STORAGE WB_S3_ENDPOINT WB_S3_BUCKET WB_S3_REGION WB_S3_KEY WB_S3_SECRET \
           WB_DATABASE_URL ${WB_SECRET_KEYS:-}; do
    [ -n "${!k:-}" ] && WB_ENGINE_ENV+=("$k=${!k}")
  done
  return 0
}

# Dispatch the requested action over the provider's hooks. `up` is the full
# converge; `secrets` stages credentials without a deploy; the rest are direct
# lifecycle calls.
wb_recipe_run() {
  wb_recipe_init
  case "${WB_RECIPE_ACTION:?}" in
    up)
      wb_base_env
      echo "==> [$WB_RECIPE_PLACE] deploying $WB_APP_NAME ($WB_IMAGE)"
      provider_ensure_app
      provider_set_secrets
      provider_attach_volume
      provider_deploy_image
      echo "url: $(provider_public_url)"
      ;;
    secrets)
      wb_base_env
      provider_ensure_app
      provider_set_secrets
      echo "secrets staged on [$WB_RECIPE_PLACE] $WB_APP_NAME"
      ;;
    down)   provider_down ;;
    status) provider_status ;;
    logs)   provider_logs ;;
    url)    provider_public_url ;;
    *) echo "unknown action: $WB_RECIPE_ACTION" >&2; exit 2 ;;
  esac
}
