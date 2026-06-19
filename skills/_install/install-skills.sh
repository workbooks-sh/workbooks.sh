#!/bin/sh
# install-skills.sh — install the Workbooks agent skills into an agent's skills dir.
# Curl-install fallback for `npx skills add workbooks-sh/workbooks.sh`.
# Usage: curl -fsSL https://workbooks.sh/install-skills.sh | sh
#        curl -fsSL https://workbooks.sh/install-skills.sh | sh -s -- <dest-dir>
#
# Skills are GENERATED from the docs and exposed in skills/ as symlinks to the
# generated bundles; -L dereferences them so the agent gets real files. The _install
# dir and the README are skipped — only actual skill folders are installed.
set -e
DEST="${1:-.claude/skills}"
REPO="https://github.com/workbooks-sh/workbooks.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git clone --depth 1 "$REPO" "$TMP" >/dev/null 2>&1
mkdir -p "$DEST"
for d in "$TMP"/skills/*/; do
  name="$(basename "$d")"
  [ "$name" = "_install" ] && continue
  cp -rfL "$d" "$DEST"/
done
echo "Installed Workbooks skills -> $DEST"
echo "Next: open the 'getting_started' skill before doing anything else."
