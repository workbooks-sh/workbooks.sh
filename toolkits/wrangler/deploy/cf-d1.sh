#!/usr/bin/env bash
# `work forge app deploy --backend cf-d1`: stands up the unified gateway (d1
# driver — D1 + Workers AI) on the USER'S OWN Cloudflare account, then injects
# the PUBLIC descriptor into a COPY of the built workbook. Only a wrangler
# login needed. Contracts: deploy-kit/app/gateway/README.org
#
# Env contract (set by `work forge app`): WB_DEPLOY_KIT, WB_FORGE_ARTIFACT,
# WB_FORGE_APP_NAME, WB_FORGE_OUT, WB_APP_AUTH (better-auth|hmac-dev),
# WB_APP_CORS, WB_APP_JWT_SECRET, WB_APP_BETTER_AUTH_SECRET,
# CLOUDFLARE_ACCOUNT_ID (required when the login has >1 account),
# WB_FORGE_NO_AUTOLOGIN.
#
# LIVE-VERIFY: the live deploy needs a real Cloudflare account; the Worker
# bundling is checked offline with `wrangler deploy --dry-run`, and core+auth
# are the SAME modules deploy-kit/app/gateway/test.sh exercises on Postgres.
set -euo pipefail

# shellcheck source=../../../deploy-kit/app/lib.sh
source "${WB_DEPLOY_KIT:?work forge sets WB_DEPLOY_KIT}/app/lib.sh"
# Shared wrangler account resolver (source-only, don't run the pages deploy).
# shellcheck source=./cloudflare.sh
WB_CF_SOURCE_ONLY=1 source "$(dirname "${BASH_SOURCE[0]}")/cloudflare.sh"

: "${WB_FORGE_ARTIFACT:?WB_FORGE_ARTIFACT (built workbook .html) required}"
: "${WB_FORGE_APP_NAME:?WB_FORGE_APP_NAME required}"
[ -f "$WB_FORGE_ARTIFACT" ] || { echo "workbook not found: $WB_FORGE_ARTIFACT" >&2; exit 1; }

command -v wrangler >/dev/null 2>&1 || {
  echo "wrangler not found — run: work forge web doctor --to cloudflare --login" >&2
  exit 1
}

slug="$(wb_app_slug "$WB_FORGE_APP_NAME")"
out="${WB_FORGE_OUT:-dist/app}"
cors="${WB_APP_CORS:-*}"
auth="${WB_APP_AUTH:-hmac-dev}"
gw="$WB_APP_DIR/gateway"
db_name="$slug"
worker_name="$slug"

if ! wrangler whoami >/dev/null 2>&1; then
  [ "${WB_FORGE_NO_AUTOLOGIN:-0}" = "1" ] && {
    echo "not signed in to Cloudflare (WB_FORGE_NO_AUTOLOGIN=1 set) — run: wrangler login" >&2; exit 1; }
  echo "==> not signed in to Cloudflare — opening the browser to sign in (wrangler login)."
  echo "    This signs into YOUR Cloudflare account; the token stays in ~/.wrangler."
  wrangler login
  wrangler whoami >/dev/null 2>&1 || { echo "login did not complete — aborting." >&2; exit 1; }
fi
wb_cf_resolve_account

# Stage the Worker (never mutate the in-repo template); deps installed here so
# wrangler/esbuild can bundle better-auth + kysely on BOTH auth paths.
stage="$(mktemp -d "${TMPDIR:-/tmp}/wb-forge-cfd1.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp "$gw/core.mjs" "$gw/auth.mjs" "$gw/d1-driver.js" "$gw/kysely-shim.mjs" \
   "$gw/package.json" "$gw/auth-gen.config.mjs" "$gw/schema.sql" "$stage/"
echo "==> npm install (worker bundle deps)"
( cd "$stage" && npm install --legacy-peer-deps --no-audit --no-fund >/dev/null 2>&1 )

# 1. D1 database (idempotent: `d1 create` prints the id; if the name is taken,
#    look the id up via `d1 list`).
echo "==> D1: ensuring database '$db_name'"
create_out="$(wrangler d1 create "$db_name" 2>&1 || true)"
db_id="$(printf '%s\n' "$create_out" | grep -oiE '[0-9a-f-]{36}' | head -1 || true)"
if [ -z "$db_id" ]; then
  db_id="$(wrangler d1 list --json 2>/dev/null \
    | grep -A4 "\"name\": *\"$db_name\"" | grep -oiE '[0-9a-f-]{36}' | head -1 || true)"
fi
[ -n "$db_id" ] || { echo "could not determine D1 database id for '$db_name'" >&2; exit 1; }
echo "    database_id=$db_id"

cat > "$stage/wrangler.toml" <<TOML
name = "$worker_name"
main = "d1-driver.js"
compatibility_date = "2026-01-01"
compatibility_flags = ["nodejs_compat"]

[[d1_databases]]
binding = "DB"
database_name = "$db_name"
database_id = "$db_id"

[ai]
binding = "AI"

[vars]
CORS_ORIGIN = "$cors"

[alias]
kysely = "./kysely-shim.mjs"
TOML

# 2. Apply the app schema to the REMOTE D1 (schema uses IF NOT EXISTS).
echo "==> D1: applying schema.sql (--remote)"
( cd "$stage" && wrangler d1 execute "$db_name" --remote --file schema.sql --yes )

# 3. Auth: BetterAuth-on-D1 (generate + apply tables + secret) or HS256 dev.
if [ "$auth" = "better-auth" ]; then
  echo "==> BetterAuth: generating + applying the auth schema to D1"
  ( cd "$stage" && npx --yes @better-auth/cli@latest generate --config ./auth-gen.config.mjs --output ./better-auth.sql -y >/dev/null 2>&1 )
  ( cd "$stage" && wrangler d1 execute "$db_name" --remote --file better-auth.sql --yes )
  ba_secret="${WB_APP_BETTER_AUTH_SECRET:-$(openssl rand -hex 32)}"
  echo "==> Worker: setting BETTER_AUTH_SECRET"
  ( cd "$stage" && printf %s "$ba_secret" | wrangler secret put BETTER_AUTH_SECRET --name "$worker_name" )
else
  jwt_secret="${WB_APP_JWT_SECRET:-$(openssl rand -hex 32)}"
  echo "==> Worker: setting GATEWAY_JWT_SECRET"
  ( cd "$stage" && printf %s "$jwt_secret" | wrangler secret put GATEWAY_JWT_SECRET --name "$worker_name" )
fi

# 4. Deploy; for BetterAuth redeploy once with BETTER_AUTH_URL now that the
#    workers.dev host is known.
echo "==> Worker: deploying '$worker_name'"
deploy_out="$( cd "$stage" && wrangler deploy 2>&1 )"
printf '%s\n' "$deploy_out"
worker_url="$(printf '%s\n' "$deploy_out" | grep -oE 'https://[A-Za-z0-9._-]+\.workers\.dev' | head -1 || true)"
[ -n "$worker_url" ] || worker_url="https://${worker_name}.workers.dev"
if [ "$auth" = "better-auth" ]; then
  ( cd "$stage" && wrangler deploy --var BETTER_AUTH_URL:"$worker_url" >/dev/null 2>&1 ) || true
fi

# 5. PUBLIC descriptor into a COPY of the workbook — no secrets in the page.
staged="$(wb_app_stage_workbook "$WB_FORGE_ARTIFACT" "$out" "$slug")"
descriptor="$(wb_app_descriptor cf-d1 "$worker_url" "$auth")"
wb_inject_descriptor "$staged" "$descriptor"

echo
echo "==> connected workbook: $staged"
echo "    backend: cf-d1 (D1 + Workers AI) @ $worker_url  ·  auth: $auth"
if [ "$auth" = "better-auth" ]; then
  echo "    sign-in: POST $worker_url/api/auth/sign-up/email | /sign-in/email (bearer in set-auth-token)"
else
  echo "    mint a dev tenant token: work forge app token --secret '<GATEWAY_JWT_SECRET>' --tenant <id>"
fi
echo "    deploy this .html with: work forge web deploy '$staged' --to cloudflare"
