#!/usr/bin/env bash
# Deploy the brandnana production engine THROUGH the deploy-kit (fly provider) —
# one deploy path, dogfooded. Equivalent CLI form:
#   WB_FLY_APP=bn-engine-agents wb deploy --place fly up
#
#   bash ci/deploy.sh                 # deploy the default app (bn-engine-agents)
#   bash ci/deploy.sh bn-engine       # cut over a specific app
#   WB_INCLUDE_CLIP=true bash ci/deploy.sh   # bake the in-BEAM ONNX CLIP embedder
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export WB_PROVIDERS_DIR="$ROOT/cli/deploy-kit/providers"
export WB_RECIPE_ACTION=up
export WB_FLY_APP="${1:-bn-engine-agents}"
export WB_INCLUDE_CLIP="${WB_INCLUDE_CLIP:-false}"
# OUR path is the APP BUILD (remote build from ci/Dockerfile + ci/fly.toml) —
# set explicitly; the recipe's default is the generic prebuilt-image path.
export WB_FLY_CONFIG="${WB_FLY_CONFIG:-ci/fly.toml}"
export WB_FLY_DOCKERFILE="${WB_FLY_DOCKERFILE:-ci/Dockerfile}"
# The recipe spine requires WB_IMAGE; on the remote-build path Fly builds the
# image, so this is just a placeholder.
export WB_IMAGE="${WB_IMAGE:-ghcr.io/workbooks-sh/runtime:latest}"

echo "deploying $WB_FLY_APP via deploy-kit (fly provider, INCLUDE_CLIP=$WB_INCLUDE_CLIP)"
exec bash "$ROOT/cli/deploy-kit/providers/fly/bootstrap.sh"
