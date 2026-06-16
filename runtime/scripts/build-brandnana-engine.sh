#!/usr/bin/env bash
# Build/deploy the clean-room brandnana engine. The Dockerfile needs both the
# clean-room runtime AND monorepo trees (brandnana CLI + profile) — but the
# runtime lives under .claude/, which the root .dockerignore excludes. So we
# ASSEMBLE a clean staging context outside .claude, then build from it.
#   bash scripts/build-brandnana-engine.sh            # local docker build
#   bash scripts/build-brandnana-engine.sh --deploy   # build + deploy bn-engine-agents
set -euo pipefail

WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"          # the clean-room runtime worktree
ROOT="${WB_MONOREPO_ROOT:-/Users/shinyobjectz/apps/workbooks}"  # the monorepo (brandnana etc.)
CTX="${BN_BUILD_CTX:-${CLAUDE_JOB_DIR:-/tmp}/tmp/bn-clean-ctx}"
IMAGE="bn-engine-clean"

echo "staging build context at $CTX"
rm -rf "$CTX"; mkdir -p "$CTX"
# All host-built artifacts are regenerated INSIDE the image — never ship them in
# the context (dist/ alone is 1.2G of stale brandnana binaries; node_modules 200M+).
EX=(--exclude _build --exclude deps --exclude .git --exclude '*.beam'
    --exclude node_modules --exclude target --exclude dist --exclude erl_crash.dump
    --exclude .svelte-kit --exclude .next)
rsync -a "${EX[@]}" "$WT/" "$CTX/runtime/"                          # the clean-room app
rsync -a "${EX[@]}" "$ROOT/projects/brandnana/" "$CTX/projects/brandnana/"  # brandnana CLI source
rsync -a "${EX[@]}" "$ROOT/substrates/brandnana/" "$CTX/substrates/brandnana/"  # profile + boards
rsync -a "${EX[@]}" "$ROOT/cli/" "$CTX/cli/"                        # work meta-CLI
cp "$WT/Dockerfile.brandnana" "$CTX/Dockerfile.brandnana"
du -sh "$CTX" | awk '{print "context size: "$1}'

if [[ "${1:-}" == "--deploy" ]]; then
  ( cd "$CTX" && fly deploy --app bn-engine-agents \
      --config "$WT/fly.brandnana.toml" \
      --dockerfile "$CTX/Dockerfile.brandnana" \
      --remote-only --yes )
else
  docker build -f "$CTX/Dockerfile.brandnana" -t "$IMAGE" "$CTX"
fi
