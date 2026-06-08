#!/usr/bin/env bash
# Deploy the brandnana production engine THROUGH the deploy-kit (fly provider) —
# one deploy path, dogfooded. Equivalent CLI form:
#   WB_FLY_APP=bn-engine-agents wb deploy --place fly up
#
#   bash deploy/deploy.sh                 # deploy the default app (bn-engine-agents)
#   bash deploy/deploy.sh bn-engine       # cut over a specific app
#   WB_INCLUDE_CLIP=true bash deploy/deploy.sh   # bake the in-BEAM ONNX CLIP embedder
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export WB_PROVIDERS_DIR="$ROOT/deploy/providers"
export WB_RECIPE_ACTION=up
export WB_FLY_APP="${1:-bn-engine-agents}"
export WB_INCLUDE_CLIP="${WB_INCLUDE_CLIP:-false}"
# The recipe spine requires WB_IMAGE; on the remote-build (Dockerfile) path Fly
# builds the image, so this is just a placeholder unless WB_IMAGE_PREBUILT is set.
export WB_IMAGE="${WB_IMAGE:-ghcr.io/workbooks-sh/runtime:latest}"

echo "deploying $WB_FLY_APP via deploy-kit (fly provider, INCLUDE_CLIP=$WB_INCLUDE_CLIP)"
exec bash "$ROOT/deploy/providers/fly/bootstrap.sh"
