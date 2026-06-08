#!/usr/bin/env bash
# Provider: fly — deploy to Fly.io. This IS the proven brandnana flow (what
# deploy/deploy.sh has always done), now behind the deploy-kit so the brandnana
# production engine deploys through `wb deploy --place fly` like everything else.
#
# Two image strategies (the deploy-kit's two faces):
#   * APP build (default): build an app image ON Fly's remote builder from a
#     Dockerfile + fly.toml — used for brandnana (deploy/Dockerfile bakes the
#     brandnana CLI + profile). WB_FLY_CONFIG + WB_FLY_DOCKERFILE.
#   * PREBUILT image: deploy a ready runtime image by ref — `wb deploy publish`'s
#     ghcr output, generic runtime. Set WB_IMAGE and leave WB_FLY_DOCKERFILE unset.
#
# Env: WB_FLY_APP (default bn-engine-agents), WB_REGION (default sjc),
#      WB_FLY_CONFIG (default deploy/fly.toml), WB_FLY_DOCKERFILE (default
#      deploy/Dockerfile), WB_INCLUDE_CLIP, WB_IMAGE (prebuilt path).
set -euo pipefail
source "${WB_PROVIDERS_DIR}/_recipe.sh"
export WB_RECIPE_PLACE=fly

command -v fly >/dev/null 2>&1 || command -v flyctl >/dev/null 2>&1 || {
  echo "flyctl not found — https://fly.io/docs/flyctl/install/" >&2; exit 1; }
FLY="$(command -v fly || command -v flyctl)"

# The app name is self-contained in the deployment.org (APP: → WB_APP_NAME);
# WB_FLY_APP overrides; falls back to the brandnana default.
APP="${WB_FLY_APP:-${WB_APP_NAME:-bn-engine-agents}}"
REGION="${WB_REGION:-sjc}"
ROOT="$(cd "${WB_PROVIDERS_DIR}/../.." && pwd)"          # repo root (deploy/providers → repo)
CONFIG="${WB_FLY_CONFIG:-deploy/fly.toml}"
DOCKERFILE="${WB_FLY_DOCKERFILE:-deploy/Dockerfile}"

# fly.toml + out-of-band `fly secrets` carry app config + the volume mount, so the
# engine-contract hooks are deploy-time no-ops here; the deploy IS one fly command.
provider_ensure_app()    { "$FLY" status --app "$APP" >/dev/null 2>&1 || { echo "app '$APP' not found — create it: fly apps create $APP" >&2; exit 1; }; }
# Stage the deployment.org axes + forwarded creds (additive; the deploy releases
# them). No generated/rotating secrets here — those stay persisted out-of-band.
provider_set_secrets()   { [ "${#WB_ENGINE_ENV[@]}" -gt 0 ] && "$FLY" secrets set --app "$APP" --stage "${WB_ENGINE_ENV[@]}" >/dev/null || true; }
provider_attach_volume() { :; }   # declared in fly.toml [mounts]

provider_deploy_image() {
  cd "$ROOT"
  if [ -n "${WB_IMAGE_PREBUILT:-}" ]; then
    echo "    fly deploy (prebuilt image): $WB_IMAGE"
    "$FLY" deploy --app "$APP" --image "$WB_IMAGE" --region "$REGION" --remote-only --yes
  else
    echo "    fly deploy (remote build): $DOCKERFILE + $CONFIG (INCLUDE_CLIP=${WB_INCLUDE_CLIP:-false})"
    "$FLY" deploy --app "$APP" --config "$CONFIG" --dockerfile "$DOCKERFILE" \
      --build-arg INCLUDE_CLIP="${WB_INCLUDE_CLIP:-false}" --remote-only --yes
  fi
}

provider_public_url() { echo "https://${APP}.fly.dev"; }

provider_down()   { "$FLY" apps destroy "$APP" --yes; }
provider_status() { "$FLY" status --app "$APP"; }
provider_logs()   { "$FLY" logs --app "$APP"; }

wb_recipe_run
