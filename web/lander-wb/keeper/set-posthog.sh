#!/usr/bin/env bash
# Securely hand the keeper its PostHog API key.
#
#   bash set-posthog.sh          # prompts (hidden input)
#   POSTHOG_API_KEY=… bash set-posthog.sh   # or from env
#
# The key is read with hidden input, never printed, never written to a file
# in this repo, and never committed. It goes straight into the deploy secrets
# store (~/Library/Application Support/sh.workbooks/secrets.env, chmod 0600)
# and is pushed to the running engine. Nothing about the value touches git.
set -euo pipefail
cd "$(dirname "$0")"

WB="${WB:-$HOME/.local/bin/wb}"; command -v "$WB" >/dev/null 2>&1 || WB="$(command -v wb)"

KEY="${POSTHOG_API_KEY:-}"
if [ -z "$KEY" ]; then
  printf 'Paste your PostHog API key (input hidden), then Enter:\n> ' >&2
  read -rs KEY
  printf '\n' >&2
fi
[ -n "$KEY" ] || { echo "no key entered — aborting" >&2; exit 1; }

# Stash locally (applied on next deploy) …
"$WB" deploy secrets set "POSTHOG_API_KEY=$KEY" >/dev/null
# … and push to the already-running engine now.
if "$WB" deploy secrets push >/dev/null 2>&1; then
  echo "✓ POSTHOG_API_KEY stored + pushed to the engine (value never printed)"
else
  echo "✓ POSTHOG_API_KEY stored — run 'wb deploy secrets push' or 'wb deploy apply' to send it"
fi
echo "  the keeper's analytics skill will use it on its next run."
