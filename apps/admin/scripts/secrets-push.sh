#!/usr/bin/env bash
set -euo pipefail
echo "Enter admin key:"
read -rs ADMIN_KEY
printf '%s' "$ADMIN_KEY" | wrangler secret put BRANDNANA_ADMIN_KEY
