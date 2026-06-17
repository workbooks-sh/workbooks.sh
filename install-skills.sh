#!/bin/sh
# install-skills.sh — install the Workbooks agent skills into an agent's skills dir.
# Curl-install fallback for `npx skills add workbooks-sh/workbooks.sh`.
# Usage: curl -fsSL https://workbooks.sh/install-skills.sh | sh
#        curl -fsSL https://workbooks.sh/install-skills.sh | sh -s -- <dest-dir>
set -e
DEST="${1:-.claude/skills}"
REPO="https://github.com/workbooks-sh/workbooks.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git clone --depth 1 "$REPO" "$TMP" >/dev/null 2>&1
mkdir -p "$DEST"
cp -rf "$TMP"/skills/* "$DEST"/
echo "Installed Workbooks skills -> $DEST"
echo "Next: open the 'getting-started' skill before doing anything else."
