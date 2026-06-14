#!/usr/bin/env bash
# sync-toolkits-subtree.sh — mirror toolkits/ to the dedicated toolkits repo.
#
# toolkits/ STAYS in this monorepo (the runtime references it directly). This
# script publishes a READ-ONLY mirror to github.com/workbooks-sh/toolkits so each
# toolkit can be consumed + versioned on its own. It's the local/manual twin of
# .github/workflows/toolkits-release.yml (which runs it automatically on push).
#
# What it does:
#   1. `git subtree split --prefix=toolkits` — synthesize a branch whose history
#      is ONLY the toolkits/ subtree (paths rewritten to repo root).
#   2. Force-push that branch to the mirror's main.
#   3. For every toolkit whose #+VERSION: bumped vs. the last sync, create + push
#      a tag  <toolkit>-v<version>  on the mirror (one tag per release).
#
# ── ONE-TIME SETUP (do this once, by a maintainer) ───────────────────────────
#   * Create the empty repo:  gh repo create workbooks-sh/toolkits --public
#   * Locally: export a PAT with `repo` scope as WB_TOOLKITS_TOKEN, or rely on
#     your existing git credentials / ssh for the push.
#   * In CI the same PAT lives in the WB_TOOLKITS_TOKEN repo secret.
#
# Usage:   bash scripts/sync-toolkits-subtree.sh
#   WB_TOOLKITS_TOKEN  optional — if set, pushes over HTTPS with the token.
#   DRY_RUN=1          print what would be pushed/tagged, don't push.
set -euo pipefail

PREFIX="toolkits"
MIRROR_OWNER="workbooks-sh"
MIRROR_REPO="toolkits"
SPLIT_BRANCH="toolkits-split"

# Repo root (run from anywhere).
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Remote URL: token form if WB_TOOLKITS_TOKEN is set, else plain HTTPS (relies on
# your git credential helper / gh auth).
if [ -n "${WB_TOOLKITS_TOKEN:-}" ]; then
  MIRROR_URL="https://x-access-token:${WB_TOOLKITS_TOKEN}@github.com/${MIRROR_OWNER}/${MIRROR_REPO}.git"
else
  MIRROR_URL="https://github.com/${MIRROR_OWNER}/${MIRROR_REPO}.git"
fi

push() { if [ "${DRY_RUN:-0}" = "1" ]; then echo "DRY_RUN: git push $*"; else git push "$@"; fi; }

echo "==> subtree split --prefix=${PREFIX}"
# Recreate the split branch from scratch each run (idempotent).
git branch -D "$SPLIT_BRANCH" 2>/dev/null || true
git subtree split --prefix="$PREFIX" -b "$SPLIT_BRANCH"

echo "==> push split -> ${MIRROR_OWNER}/${MIRROR_REPO}:main"
# Force: the mirror's main is always a faithful copy of the current subtree.
push "$MIRROR_URL" "${SPLIT_BRANCH}:refs/heads/main" --force

# ── Per-toolkit release tags ────────────────────────────────────────────────
# A toolkit is released as the tag <toolkit>-v<version>, read from its
# manifest.org (#+TOOLKIT: / #+VERSION:). We only push a tag that doesn't already
# exist on the mirror — so re-running is safe, and a tag appears exactly when a
# #+VERSION: is first seen at that value.
echo "==> tagging changed toolkit versions"
EXISTING="$(git ls-remote --tags "$MIRROR_URL" 2>/dev/null | sed 's#.*refs/tags/##;s/\^{}//' | sort -u || true)"

for manifest in "$PREFIX"/*/manifest.org; do
  [ -f "$manifest" ] || continue
  name="$(grep -m1 -E '^#\+TOOLKIT:' "$manifest" | sed -E 's/^#\+TOOLKIT:[[:space:]]*//;s/[[:space:]]*$//')"
  version="$(grep -m1 -E '^#\+VERSION:' "$manifest" | sed -E 's/^#\+VERSION:[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$name" ] && [ -n "$version" ] || { echo "  skip $manifest (no TOOLKIT/VERSION)"; continue; }

  tag="${name}-v${version}"
  if printf '%s\n' "$EXISTING" | grep -qx "$tag"; then
    echo "  = $tag already released"
    continue
  fi

  echo "  + $tag"
  # Tag the tip of the split branch (the mirror's main commit).
  git tag -f "$tag" "$SPLIT_BRANCH"
  push "$MIRROR_URL" "refs/tags/${tag}" --force
done

echo "==> done."
