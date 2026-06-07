#!/usr/bin/env bash
set -euo pipefail
VERSION="${1:?usage: publish-binaries.sh <version>}"
BUCKET="brandnana-binaries"
DIST="$(cd "$(dirname "$0")/../../cli/dist" && pwd)"

if [ ! -d "$DIST" ]; then
  echo "error: dist dir not found at $DIST — run 'bun run build:binary' in apps/cli first"
  exit 1
fi

for f in "$DIST"/brandnana-*; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  echo "uploading $name -> r2://$BUCKET/$VERSION/$name"
  wrangler r2 object put "$BUCKET/$VERSION/$name" --file="$f"
  echo "uploading $name -> r2://$BUCKET/latest/$name"
  wrangler r2 object put "$BUCKET/latest/$name" --file="$f"
done

# checksums
( cd "$DIST" && shasum -a 256 brandnana-* > SHA256SUMS )
wrangler r2 object put "$BUCKET/$VERSION/SHA256SUMS" --file="$DIST/SHA256SUMS"
wrangler r2 object put "$BUCKET/latest/SHA256SUMS" --file="$DIST/SHA256SUMS"

echo
echo "done: binaries live at r2://$BUCKET/$VERSION/ and r2://$BUCKET/latest/"
