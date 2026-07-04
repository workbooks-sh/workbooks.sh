# Thin dogfood image — the prebuilt runtime base + the dogfood CONTENT tree only. A content change
# (cloud dashboard views, lander copy, deploy config) rebuilds JUST this COPY layer in seconds; the
# Elixir release lives in dogfood-base (dogfood/deploy/Dockerfile.base), rebuilt only when nexus/
# changes (see .github/workflows/dogfood-deploy.yml).
#
# BASE is pinned to a sha by CI when the runtime changed, else :latest. Build from the repo root:
#   docker build --build-arg BASE=<ref> -f dogfood/deploy/Dockerfile .
ARG BASE=ghcr.io/workbooks-sh/dogfood-base:latest
FROM ${BASE}
# The deploy config + workbook tree. Nexus.Config reads $WB_DATA/index.work (= /srv/dogfood/index.work);
# the surfaces (cloud, lander, docs, …) are served from this tree. This is the ONLY layer a content
# deploy rebuilds. CMD/entrypoint/litestream all come from the base.
# CACHEBUST forces a fresh COPY every deploy — fly's remote builder was reusing a
# stale content layer, silently shipping images without newly-added surfaces even
# under --no-cache (a new lander page never reached the running nexus). Pass a
# changing value: fly deploy --build-arg CACHEBUST=$(date +%s).
ARG CACHEBUST=0
COPY dogfood /srv/dogfood
# Guard: fail the build LOUDLY if the content layer is stale, rather than deploy a
# silently-missing tree. Add a sentinel here for any surface that MUST ship.
RUN test -f /srv/dogfood/lander/privacy/index.work \
  || (echo "STALE CONTENT LAYER — lander/privacy missing from image" && exit 1)
