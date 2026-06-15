#!/usr/bin/env bash
# Build the local-ACP agent image (arm64) with buildah. EXPERIMENTAL (wb-xiei.8).
set -euo pipefail
cd "$(dirname "$0")"
IMAGE="${WB_ACP_IMAGE:-localhost/wb-acp-agent:latest}"
echo "building $IMAGE (linux/arm64) …"
buildah bud --arch arm64 -f Dockerfile.agent -t "$IMAGE" .
echo "built $IMAGE"
