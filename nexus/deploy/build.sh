#!/usr/bin/env bash
# Build the nexus runtime OCI image — the ONE image the desktop daemon + Nexus.Deploy.Machine boot.
#
# The build CONTEXT is the REPO ROOT. nexus is self-contained (vendor/wasmex + priv/work-toolchain.wasm
# under nexus/), but the in-sandbox compilers — a ~7G gitignored toolchain NOT in git — ship as a
# SEPARATE image stage the nexus Dockerfile pulls via `COPY --from=compilers`. So this is a TWO-STEP
# build:
#   1. compilers image  (ci/Dockerfile.compilers: FROM scratch + COPY nexus/compilers-dist /compilers)
#   2. nexus image      (nexus/Dockerfile: --build-arg COMPILERS_REF=<compilers image>)
#
# Usage:   nexus/deploy/build.sh [IMAGE_TAG]
#   IMAGE_TAG       defaults to nexus:local
# Env:
#   COMPILERS_TAG   the local compilers image tag           (default: compilers:local)
#   COMPILERS_REF   skip building the compilers image, use this ref (e.g. ghcr.io/workbooks-sh/compilers:latest)
#   SKIP_STAGE=1    skip stage-tools.sh (nexus/compilers-dist already populated — it usually is)
#   PLATFORM        e.g. linux/arm64 (default: host arch, for the krunvm mac case)
#   INTO_KRUNVM=1   after building, copy the image into krunvm's store (needs skopeo)
#
# You cannot build this without the provisioned compilers staged at nexus/compilers-dist. On a machine
# without them, stage-tools.sh fails — provision the compilers first.
set -euo pipefail

TAG="${1:-nexus:local}"
COMPILERS_TAG="${COMPILERS_TAG:-compilers:local}"
COMPILERS_DIST="nexus/compilers-dist"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

# Stage the reactor toolchain wasm into nexus/priv (cheap; the Dockerfile bakes it into the release).
[ -x "$ROOT/nexus/scripts/stage-cli.sh" ] && bash "$ROOT/nexus/scripts/stage-cli.sh" || true

# Stage the lean in-sandbox compilers (gitignored ~7G toolchain → ~600M) unless already present.
if [ "${SKIP_STAGE:-0}" != "1" ] && [ ! -d "$ROOT/$COMPILERS_DIST" ]; then
  STAGE="$ROOT/nexus/scripts/stage-tools.sh"
  if [ -f "$STAGE" ]; then
    echo "==> staging compilers via $STAGE"
    ( cd "$ROOT/nexus" && bash "$STAGE" )
  else
    echo "!! $STAGE missing and $COMPILERS_DIST absent — provision the in-sandbox compilers first." >&2
    exit 1
  fi
fi
[ -d "$ROOT/$COMPILERS_DIST" ] || { echo "!! $COMPILERS_DIST not present — cannot bundle the compilers." >&2; exit 1; }

PLATFORM_ARG=()
[ -n "${PLATFORM:-}" ] && PLATFORM_ARG=(--platform "$PLATFORM")

# Step 1: the compilers image (skipped if COMPILERS_REF was supplied, e.g. the ghcr ref).
COMPILERS_REF="${COMPILERS_REF:-}"
if [ -z "$COMPILERS_REF" ]; then
  echo "==> [1/2] docker build $COMPILERS_TAG (ci/Dockerfile.compilers, context=$COMPILERS_DIST only)"
  DOCKER_BUILDKIT=1 docker build -f ci/Dockerfile.compilers "${PLATFORM_ARG[@]}" -t "$COMPILERS_TAG" .
  COMPILERS_REF="$COMPILERS_TAG"
fi

# Step 2: the nexus image, pulling the compilers from the stage above.
echo "==> [2/2] docker build $TAG (nexus/Dockerfile, COMPILERS_REF=$COMPILERS_REF)"
DOCKER_BUILDKIT=1 docker build \
  -f nexus/Dockerfile \
  "${PLATFORM_ARG[@]}" \
  --build-arg "COMPILERS_REF=$COMPILERS_REF" \
  -t "$TAG" \
  .

# Stage into krunvm's containers store so `Nexus.Deploy.local/2` boots it offline. Needs skopeo.
if [ "${INTO_KRUNVM:-0}" = "1" ]; then
  echo "==> skopeo copy → krunvm store"
  skopeo copy "docker-daemon:$TAG" "containers-storage:$TAG"
fi

echo "==> built $TAG"
