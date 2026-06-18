#!/usr/bin/env bash
# Build the nexus runtime OCI image — the ONE image Nexus.Deploy.Machine boots in a krunvm microVM.
#
# Mirrors the runtime's image build (runtime/host/deploy/image.ex): the build CONTEXT is the REPO
# ROOT (nexus depends on ../runtime/vendor/wasmex and the compilers, both outside nexus/), and the
# in-sandbox compilers — a ~7.1G gitignored toolchain that is NOT in git — must be STAGED into the
# context before the build. We stage the lean ~600M slice via runtime/scripts/stage-tools.sh →
# runtime/compilers-dist (exactly as the runtime image does), then COPY that into the image.
#
# Usage:   nexus/deploy/build.sh [IMAGE_TAG]
#   IMAGE_TAG   defaults to nexus:local
# Env:
#   COMPILERS_DIR   context path holding compilers/<lang>/   (default: runtime/compilers-dist)
#   SKIP_STAGE=1    skip stage-tools.sh (COMPILERS_DIR already populated)
#   PLATFORM        e.g. linux/arm64 (default: host arch, for the krunvm mac case)
#   INTO_KRUNVM=1   after building, copy the image into krunvm's store (needs skopeo)
#
# NOTE: you cannot build this without the provisioned compilers present. On a machine without the
# toolchain, stage-tools.sh fails — that's expected; provision the compilers first.
set -euo pipefail

TAG="${1:-nexus:local}"
COMPILERS_DIR="${COMPILERS_DIR:-runtime/compilers-dist}"

# Repo root = two levels up from this script (nexus/deploy/build.sh).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

# Stage the lean in-sandbox compilers into $COMPILERS_DIR (the gitignored ~7.1G toolchain → ~600M).
if [ "${SKIP_STAGE:-0}" != "1" ]; then
  STAGE="$ROOT/runtime/scripts/stage-tools.sh"
  if [ -x "$STAGE" ] || [ -f "$STAGE" ]; then
    echo "==> staging compilers via $STAGE"
    ( cd "$ROOT/runtime" && bash "$STAGE" )
  else
    echo "!! $STAGE missing — provision the in-sandbox compilers first, or set SKIP_STAGE=1 with" >&2
    echo "   $COMPILERS_DIR pre-populated. The compilers are NOT in git (a ~7.1G build artifact)." >&2
    exit 1
  fi
fi

if [ ! -d "$ROOT/$COMPILERS_DIR" ]; then
  echo "!! $COMPILERS_DIR not present in the build context — the image cannot bundle the compilers." >&2
  exit 1
fi

PLATFORM_ARG=()
[ -n "${PLATFORM:-}" ] && PLATFORM_ARG=(--platform "$PLATFORM")

echo "==> docker build -t $TAG (context=$ROOT, compilers=$COMPILERS_DIR)"
DOCKER_BUILDKIT=1 docker build \
  -f nexus/Dockerfile \
  "${PLATFORM_ARG[@]}" \
  --build-arg "COMPILERS_DIR=$COMPILERS_DIR" \
  -t "$TAG" \
  .

# Stage into krunvm's containers store so `Nexus.Deploy.local/2` boots it offline (mirrors
# image.ex into_krunvm/1). Needs skopeo (`brew install skopeo`).
if [ "${INTO_KRUNVM:-0}" = "1" ]; then
  echo "==> skopeo copy → krunvm store"
  skopeo copy "docker-daemon:$TAG" "containers-storage:$TAG"
fi

echo "==> built $TAG"
