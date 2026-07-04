#!/usr/bin/env bash
# Provider: fly — deploy to Fly.io. Fly is OUR personal preference, not a
# privileged target: this is just one recipe behind the provider-neutral spine;
# any PaaS gets its own <place>/bootstrap.sh with the same hooks.
#
# Two image strategies:
#   * PREBUILT image (default for kit users): deploy a ready runtime image by
#     ref (WB_IMAGE, e.g. ghcr.io/workbooks-sh/runtime:latest). The recipe
#     synthesizes a minimal fly.toml (port + /data volume) — no repo needed.
#   * APP build (ours, opt-in): build ON Fly's remote builder from a Dockerfile +
#     fly.toml — set WB_FLY_CONFIG and/or WB_FLY_DOCKERFILE (brandnana: ci/).
#
# Env: WB_APP_NAME (default workbooks; WB_FLY_APP overrides), WB_REGION (sjc),
#      WB_IMAGE, WB_FLY_CONFIG, WB_FLY_DOCKERFILE, WB_INCLUDE_CLIP, WB_PORT.
set -euo pipefail
source "${WB_PROVIDERS_DIR}/_recipe.sh"
export WB_RECIPE_PLACE=fly

command -v fly >/dev/null 2>&1 || command -v flyctl >/dev/null 2>&1 || {
  echo "flyctl not found — https://fly.io/docs/flyctl/install/" >&2; exit 1; }
FLY="$(command -v fly || command -v flyctl)"

APP="${WB_FLY_APP:-${WB_APP_NAME:-workbooks}}"
REGION="${WB_REGION:-sjc}"

# App-build mode only when explicitly configured (our brandnana path); kit users
# deploy the prebuilt runtime image.
APP_BUILD=""
[ -n "${WB_FLY_CONFIG:-}" ] || [ -n "${WB_FLY_DOCKERFILE:-}" ] && APP_BUILD=1

# Converge, don't complain: create the app if it's missing.
provider_ensure_app() {
  "$FLY" status --app "$APP" >/dev/null 2>&1 ||
    "$FLY" apps create "$APP" >/dev/null
}

# Stage the deployment.org axes + forwarded creds (additive; the deploy releases
# them). No generated/rotating secrets here — those stay persisted out-of-band.
provider_set_secrets() {
  [ "${#WB_ENGINE_ENV[@]}" -gt 0 ] &&
    "$FLY" secrets set --app "$APP" --stage "${WB_ENGINE_ENV[@]}" >/dev/null || true
}

# Prebuilt path: a real volume so WB_DATA survives machine replacement.
# App-build path: declared in the repo fly.toml [mounts].
provider_attach_volume() {
  [ -n "$APP_BUILD" ] && return 0
  "$FLY" volumes list --app "$APP" 2>/dev/null | grep -q wbdata ||
    "$FLY" volumes create wbdata --app "$APP" --region "$REGION" --size 1 --yes >/dev/null
}

provider_deploy_image() {
  if [ -n "$APP_BUILD" ]; then
    ROOT="$(cd "${WB_PROVIDERS_DIR}/../../.." && pwd)" # repo root (app-build is repo-dev only)
    cd "$ROOT"
    CONFIG="${WB_FLY_CONFIG:-ci/fly.toml}"
    DOCKERFILE="${WB_FLY_DOCKERFILE:-ci/Dockerfile}"
    echo "    fly deploy (remote build): $DOCKERFILE + $CONFIG (INCLUDE_CLIP=${WB_INCLUDE_CLIP:-false})"
    "$FLY" deploy --app "$APP" --config "$CONFIG" --dockerfile "$DOCKERFILE" \
      --build-arg INCLUDE_CLIP="${WB_INCLUDE_CLIP:-false}" --remote-only --yes
  else
    # Synthesize a minimal config: engine contract = container + port + volume.
    TMP="$(mktemp -d)"
    cat > "$TMP/fly.toml" <<EOF
app = "$APP"
primary_region = "$REGION"

[build]
  image = "$WB_IMAGE"

[mounts]
  source = "wbdata"
  destination = "${WB_DATA:-/data}"

[http_service]
  internal_port = ${WB_PORT:-4000}
  force_https = true
  auto_stop_machines = "stop"
  auto_start_machines = true
  min_machines_running = 0
EOF
    echo "    fly deploy (prebuilt image): $WB_IMAGE"
    "$FLY" deploy --app "$APP" --config "$TMP/fly.toml" --regions "$REGION" --yes
    rm -rf "$TMP"
  fi
}

provider_public_url() { echo "https://${APP}.fly.dev"; }

provider_down()   { "$FLY" apps destroy "$APP" --yes; }
provider_status() { "$FLY" status --app "$APP"; }
provider_logs()   { "$FLY" logs --app "$APP" --no-tail; }

wb_recipe_run
