#!/usr/bin/env bash
# Workbooks.Deploy.Backend — the provider-neutral recipe spine. Each cloud place
# is cli/deploy-kit/providers/<place>/bootstrap.sh: it sources THIS, fills the five hooks
#   provider_ensure_app / provider_set_secrets / provider_attach_volume /
#   provider_deploy_image / provider_public_url
# plus the lifecycle trio (provider_down / provider_status / provider_logs),
# sets WB_RECIPE_PLACE, and calls `wb_recipe_run`. The deploy-kit invokes the
# bootstrap with WB_RECIPE_ACTION (up|down|status|logs) + the assembled env.
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
# axes (tenancy + BYOD storage/db + profile/region, already resolved into env by
# Workbooks.Deploy.Config) plus credential VALUES forwarded from the deployer's
# env. NOTE: generated secrets (WB_SIGNING_KEY / WB_PUBLIC_BEARER) are deliberately
# NOT minted here — rotating them 401s live clients and breaks the tenant DID.
# They are persisted operator secrets, set once out-of-band.
wb_base_env() {
  WB_ENGINE_ENV=("WB_WEB=1" "PORT=${WB_PORT}" "WB_DATA=${WB_DATA}" "WB_EMBED=${WB_EMBED:-local}")
  local k
  for k in WB_TENANCY_MODE WB_PROFILE_DIR WB_REGION \
           WB_STORAGE WB_S3_ENDPOINT WB_S3_BUCKET WB_S3_REGION WB_S3_KEY WB_S3_SECRET \
           WB_DATABASE_URL OPENROUTER_API_KEY GEMINI_API_KEY FIRECRAWL_API_KEY; do
    [ -n "${!k:-}" ] && WB_ENGINE_ENV+=("$k=${!k}")
  done
  return 0
}

# Dispatch the requested action over the provider's hooks. `up` is the full
# converge; the rest are direct lifecycle calls.
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
    down)   provider_down ;;
    status) provider_status ;;
    logs)   provider_logs ;;
    url)    provider_public_url ;;
    *) echo "unknown action: $WB_RECIPE_ACTION" >&2; exit 2 ;;
  esac
}
