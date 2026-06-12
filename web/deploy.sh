#!/bin/sh
# Deploy the public site: ships a FILTERED copy of web/ to Cloudflare Pages.
# Pages has no server-side ignore, so exclusion happens here — everything in
# .assetsignore (pipeline internals, raw takes, experiments) stays home.
set -e
cd "$(dirname "$0")"
STAGE=$(mktemp -d /tmp/wb-site-deploy.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
rsync -a --exclude-from=.assetsignore --exclude=.assetsignore --exclude=deploy.sh ./ "$STAGE/"
echo "staged $(du -sh "$STAGE" | cut -f1) (filtered from $(du -sh . | cut -f1))"
CLOUDFLARE_ACCOUNT_ID=${CLOUDFLARE_ACCOUNT_ID:-6d4b74aeb10f455fbf88141901e7595d} \
  npx wrangler pages deploy "$STAGE" --project-name workbooks-shell --commit-dirty=true
