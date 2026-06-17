#!/usr/bin/env bash
# build-toolkits-site.sh — regenerate the toolkit MARKETPLACE under web/toolkits/.
#
# Runs web/toolkits/gen-marketplace.py, which reads every
# toolkits/<slug>/manifest.org and rewrites web/toolkits/ (catalog.json,
# index.html, and one <slug>.html detail page per toolkit). Stdlib Python only,
# no deps. This is the local twin of the `marketplace` job in
# .github/workflows/toolkits-release.yml — run it after editing any manifest so
# the published site stays in sync with the toolkits repo.
#
# Usage:  scripts/build-toolkits-site.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PYTHON:-python3}"

"$PY" "$ROOT/web/toolkits/gen-marketplace.py"

echo "toolkits site regenerated → $ROOT/web/toolkits/"
