# cloudflare

The all-Cloudflare path for a forged workbook: a live, multi-tenant app standing entirely on the user's own Cloudflare account — D1 for data, Workers AI for AI features, BetterAuth for sign-in, and Pages for hosting — with just a `wrangler` login. One provider, one account, one bill.

## When to reach for it

Reach for `cloudflare` when you want a workbook's backend to live on a single account with no second provider to provision. It's the sibling of `byod` (Postgres + Railway); pick this one for an all-Cloudflare stack.

## Example

```
wrangler login
wrangler d1 create <slug>               # data: create the D1 database
wrangler d1 execute <slug> --remote --file schema.sql
wrangler deploy                         # your Worker (D1 + [ai] binding + BetterAuth)
# ship the .html frontend with the wrangler toolkit: wrangler pages deploy
```

## What it grants

- The architecture + the **real raw-`wrangler` primitives** to build an all-Cloudflare backend: D1 (tenant-scoped SQLite) + Workers AI + BetterAuth-on-D1 at `/api/auth/*`, with the `.html` frontend on Pages.
- Automatic account selection from `wrangler whoami` (set `CLOUDFLARE_ACCOUNT_ID` if you have several).

## Maturity

Experimental. The turnkey one-command deploy (`work forge app deploy --backend cf-d1`) and its bundled gateway Worker were removed 2026-06-09 and are **not currently available** (restore-or-drop tracked in `wb-dtd0.1`); the skill gives the raw primitives to build it today. Uses wrangler's own token in `~/.wrangler` — Workbooks never reads, stores, or proxies it. Requires wrangler 3+.
