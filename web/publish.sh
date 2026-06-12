#!/usr/bin/env bash
# Publish workbooks.sh — stage web/, bake feature flags, deploy to Cloudflare
# Pages (workbooks-shell). One command; rerun freely.
#   bash web/publish.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d)"
cp -R "$ROOT/web/"* "$STAGE/"
rm -rf "$STAGE/brand" "$STAGE/og/build.py" "$STAGE/publish.sh"
cp -f "$ROOT/desktop/scripts/install.sh" "$STAGE/install.sh"
find "$STAGE" -name "._*" -delete

# Bake flags into the static HTML — no flash of flagged-off UI before JS runs.
python3 - "$STAGE" <<'PY'
import glob, re, sys
stage = sys.argv[1]
for f in [stage + "/index.html"] + glob.glob(stage + "/learn/*.html"):
    s = open(f).read()
    if "WB_FLAGS" not in s and "btn-dl" not in s and 'class="dl"' not in s.replace("nav .dl",""): continue
    # desktopDownload=false → remove download anchor + nav CTA from markup
    s = re.sub(r'\n?\s*<a class="btn btn-dl[^>]*>.*?</a>', "", s, flags=re.S)
    s = re.sub(r'\n?\s*<a class="dl"[^>]*>.*?</a>', "", s, flags=re.S)
    open(f, "w").write(s)
print("flags baked")
PY

export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-6d4b74aeb10f455fbf88141901e7595d}"
wrangler pages deploy "$STAGE" --project-name=workbooks-shell --branch=main --commit-dirty=true
rm -rf "$STAGE"

# Refresh the fly origin (root data source) from GitHub main — push first.
if command -v fly >/dev/null 2>&1 && fly status --app wb-site >/dev/null 2>&1; then
  echo "refreshing origin wb-site from GitHub main…"
  fly ssh console -a wb-site -C "sh -c 'set -e; rm -rf /tmp/r; git clone -q --depth 1 https://github.com/workbooks-sh/workbooks.sh /tmp/r; rm -rf /data/build/public/wb-site; mkdir -p /data/build/public/wb-site; cp -r /tmp/r/web/. /data/build/public/wb-site/; rm -rf /data/build/public/wb-site/brand /data/build/public/wb-site/og/build.py /data/build/public/wb-site/publish.sh /data/build/public/wb-site/deploy /data/build/public/wb-site/_worker.js; cp /tmp/r/desktop/scripts/install.sh /data/build/public/wb-site/install.sh; echo origin-refreshed'" 2>&1 | tail -1
fi
