#!/bin/sh
# Runs ON the wb-site machine: sync the served tree from GitHub main.
# Single source — CI and web/publish.sh both ship this via base64.
# Sparse checkout on the volume (not /tmp: too small for a full clone).
set -e
if [ -d /data/src/.git ]; then
  cd /data/src
  git fetch -q --depth 1 origin main
  git reset -q --hard origin/main
else
  rm -rf /data/src
  git clone -q --depth 1 --filter=blob:none --sparse \
    https://github.com/workbooks-sh/workbooks.sh /data/src
  cd /data/src
  git sparse-checkout set web desktop/scripts
fi
NEW=/data/build/public/wb-site.new
LIVE=/data/build/public/wb-site
rm -rf "$NEW"
mkdir -p "$NEW"
cp -r /data/src/web/. "$NEW/"
rm -rf "$NEW/brand" "$NEW/og/build.py" "$NEW/publish.sh" "$NEW/deploy" "$NEW/_worker.js"
cp /data/src/desktop/scripts/install.sh "$NEW/install.sh"
rm -rf "$LIVE.old"
[ -d "$LIVE" ] && mv "$LIVE" "$LIVE.old"
mv "$NEW" "$LIVE"
rm -rf "$LIVE.old"
echo "origin-refreshed @ $(cd /data/src && git rev-parse --short HEAD)"
