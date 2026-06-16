#!/usr/bin/env bash
# `work deploy apply` (ENGINE_PLACE=fly). Headless model: the engine runs the
# agent loop as a local subprocess on its own Fly machine (WB_VMM_BACKEND=
# process); fly-machines is Fly's native machine-per-run sandbox backend.
# Spine + hook contract: deploy-kit/recipe/common.sh + deploy-kit/README.org.
set -euo pipefail

command -v flyctl >/dev/null 2>&1 || {
  echo "flyctl not found — install from https://fly.io/docs/flyctl/install/" >&2
  exit 1
}

# shellcheck source=../../../deploy-kit/recipe/common.sh
source "$WB_DEPLOY_KIT/recipe/common.sh"
wb_recipe_init
export WB_RECIPE_PLACE=fly

echo "==> Workbooks Engine → Fly (headless${UPDATE:+, update=$UPDATE}): app=$WB_APP_NAME region=$WB_REGION"
echo "    profile: $WB_PROFILE"

wb_base_secret_args

# Fly-native sandbox wiring. WB_VMM_BACKEND = the engine's selector;
# WBVM_BACKEND = the Rust workbooks-vmm helper's (it inherits the machine env).
FLY_FORWARD_EXTRA=""
FLY_BUILD_ARGS=()
case "${WB_SANDBOX_RUN:-in-process}" in
  fly-machines)
    SECRET_ARGS+=("WBVM_BACKEND=fly-machines")
    WBVM_FLY_APP="${WBVM_FLY_APP:-${WB_APP_NAME}-agents}"
    SECRET_ARGS+=("WBVM_FLY_APP=${WBVM_FLY_APP}")
    : "${WBVM_FLY_IMAGE:?WB_SANDBOX_RUN=fly-machines needs WBVM_FLY_IMAGE (e.g. ghcr.io/workbooks-sh/agent-runtime:vX.Y.Z) in your env}"
    SECRET_ARGS+=("WBVM_FLY_IMAGE=${WBVM_FLY_IMAGE}")
    SECRET_ARGS+=("WBVM_FLY_REGION=${WBVM_FLY_REGION:-$WB_REGION}")
    : "${FLY_API_TOKEN:?WB_SANDBOX_RUN=fly-machines needs FLY_API_TOKEN in your env (api.machines.dev bearer)}"
    SECRET_ARGS+=("WB_VMM_BACKEND=fly-machines")
    # The engine image must carry the helper built --features fly-machines.
    FLY_BUILD_ARGS+=(--build-arg WITH_VMM_HELPER=1)
    echo "    fly-machines: building with WITH_VMM_HELPER=1 (bakes the helper)"
    FLY_FORWARD_EXTRA="FLY_API_TOKEN"
    ;;
  in-process|process|"")
    SECRET_ARGS+=("WB_VMM_BACKEND=process")
    ;;
  *)
    echo "    WARN: WB_SANDBOX_RUN='$WB_SANDBOX_RUN' not supported on the Fly bootstrap" >&2
    echo "          (expected fly-machines | in-process) — defaulting engine to process" >&2
    SECRET_ARGS+=("WB_VMM_BACKEND=process")
    ;;
esac

# Declared profile ⇒ bake it. WB_PROFILE is exported by `work deploy` (and
# required by wb_recipe_init); without this the source build defaults to
# WITH_PROFILE=0 and ships a lean engine — empty /opt/profile + /opt/toolkits,
# no wb/brandnana binaries — breaking every harvest verb and board agent
# (brandnana parity gap-1).
if [ -n "${WB_PROFILE:-}" ]; then
  FLY_BUILD_ARGS+=(--build-arg WITH_PROFILE=1)
  echo "    profile declared: building with WITH_PROFILE=1 (bakes profile + toolkits + CLIs)"
fi

wb_append_forward_secrets "$FLY_FORWARD_EXTRA"

provider_ensure_app() {
  if [ "$UPDATE" = 1 ]; then
    flyctl status --app "$WB_APP_NAME" >/dev/null 2>&1 || {
      echo "    update: app '$WB_APP_NAME' does not exist — run \`work deploy apply\` first" >&2
      exit 1
    }
    echo "    update: converging existing app in place"
  else
    flyctl apps create "$WB_APP_NAME" 2>/dev/null || echo "    engine app exists"
  fi
}

provider_set_secrets() {
  # Staged so they land with the next deploy (never baked in the image).
  flyctl secrets set --app "$WB_APP_NAME" --stage "${SECRET_ARGS[@]}"
}

provider_attach_volume() {
  # Declarative via the [mounts] block in engine.toml.template.
  :
}

provider_deploy_image() {
  # WB_IMAGE (prebuilt, no build) wins; else build on Fly's remote builder
  # from the ONE engine Dockerfile (context = monorepo root).
  local rendered
  rendered="$(mktemp -t wb-engine-XXXX).toml"
  sed -e "s/__APP_NAME__/$WB_APP_NAME/g" -e "s/__REGION__/$WB_REGION/g" \
    "$(dirname "${BASH_SOURCE[0]}")/engine.toml.template" > "$rendered"
  if [ -n "${WB_IMAGE:-}" ]; then
    echo "    deploying prebuilt image: $WB_IMAGE (skipping source build)"
    flyctl deploy --app "$WB_APP_NAME" --config "$rendered" --image "$WB_IMAGE"
  else
    local dockerfile_rel="${WB_DOCKERFILE:-Dockerfile.engine}"
    local deploy_flags=(--remote-only)
    [ "$UPDATE" = 1 ] && deploy_flags+=(--strategy bluegreen)
    flyctl deploy "$REPO_ROOT" --app "$WB_APP_NAME" --config "$rendered" \
      --dockerfile "$WB_DEPLOY_KIT/$dockerfile_rel" \
      ${FLY_BUILD_ARGS[@]+"${FLY_BUILD_ARGS[@]}"} "${deploy_flags[@]}"
  fi
  rm -f "$rendered"
}

provider_public_url() { echo "https://${WB_APP_NAME}.fly.dev"; }

wb_recipe_run
