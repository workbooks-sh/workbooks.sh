# cloudflare

The all-Cloudflare path for a forged workbook: a live, multi-tenant app standing entirely on the user's own Cloudflare account — D1 for data, Workers AI for AI features, BetterAuth for sign-in, and Pages for hosting — with just a `wrangler` login. One provider, one account, one bill.

## When to reach for it

Reach for `cloudflare` when you want a workbook's backend to live on a single account with no second provider to provision. It's the sibling of `byod` (Postgres + Railway); pick this one for an all-Cloudflare stack.

## Example

```
wrangler login
wb forge app deploy --backend cf-d1     # D1 + Workers AI gateway Worker
wb forge web deploy --to cloudflare     # ship the .html to Pages
# BetterAuth mounts at /api/auth/* when BETTER_AUTH_SECRET is set
```

## What it grants

- Data + AI: a unified gateway Worker with a D1 driver — tenant-scoped SQLite plus Workers AI.
- Auth: BetterAuth-on-D1 at `/api/auth/*` (sessions, organizations, JWKS, bearer); an HS256 dev-token fallback when no secret is set.
- Hosting: the workbook `.html` frontend on Cloudflare Pages.
- Automatic account selection from `wrangler whoami` (set `CLOUDFLARE_ACCOUNT_ID` if you have several).

## Maturity

Experimental. Uses wrangler's own token in `~/.wrangler` — Workbooks never reads, stores, or proxies it. Requires wrangler 3+.
