#!/usr/bin/env bash
# Apply every packages/schema/migrations-server/*.sql to the D1 binding
# in order. Migrations use `CREATE … IF NOT EXISTS`, so re-runs are safe.
#
# Usage:
#   bash apps/api/scripts/d1-migrate.sh             # remote (production)
#   bash apps/api/scripts/d1-migrate.sh --local     # local dev D1
set -euo pipefail

API_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$API_DIR/../.." && pwd)"
MIG_DIR="$REPO_ROOT/packages/schema/migrations-server"

TARGET="--remote"
if [[ "${1:-}" == "--local" ]]; then
  TARGET="--local"
fi

cd "$API_DIR"
shopt -s nullglob
for sql in "$MIG_DIR"/[0-9]*.sql; do
  name="$(basename "$sql")"
  echo "==> applying $name ($TARGET)"
  bunx wrangler d1 execute brandnana "$TARGET" --file "$sql"
done
echo "✓ D1 migrations applied"
