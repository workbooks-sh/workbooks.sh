#!/usr/bin/env bash
# Build the local-ACP agent image (arm64) with buildah. EXPERIMENTAL (wb-xiei.8).
set -euo pipefail
cd "$(dirname "$0")"
IMAGE="${WB_ACP_IMAGE:-localhost/wb-acp-agent:latest}"
echo "building $IMAGE (linux/arm64) …"
# --platform pins BOTH os+arch (buildah otherwise picks the host OS = darwin and
# fails to find a darwin/arm64 layer in the linux manifest).
buildah bud --platform linux/arm64 -f Dockerfile.agent -t "$IMAGE" .
echo "built $IMAGE"
