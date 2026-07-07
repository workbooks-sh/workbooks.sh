# Deploying the dogfood site (workbooks.sh)

`workbooks.sh` = a **nexus on Fly** (`wb-dogfood`) serving `dogfood/` as `.work`, fronted by the
Cloudflare Worker (`web/_worker.js` → origin `wb-dogfood.fly.dev`, `/` → the lander).

## Redeploy the nexus (after changing dogfood/ or nexus/)

The published `ghcr.io/workbooks-sh/runtime:latest` may be stale (CI runtime-image build is currently
broken), so build from source. A slim image (no wasm compilers — dogfood compiles no wasm):

The repo-root `.dockerignore` is the single source of truth and is applied automatically (the build
context is the repo root), so no copy step is needed — it shrinks the context and drops the stale NIF:

```
fly deploy -a wb-dogfood --config dogfood/deploy/fly.toml \
  --dockerfile dogfood/deploy/Dockerfile --remote-only --ha=false
```

`--remote-only` builds amd64 natively (a local Mac build is arm64 → "invalid ELF header" crash).

## Repoint / republish the edge

```
wrangler pages deploy web --project-name=workbooks-shell --branch=main --commit-dirty=true
```

Backup of the pre-flip worker (fronted wb-site): `/tmp/_worker.js.wb-site-bak` (or git history).
