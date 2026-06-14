# wrangler

A wrapper around the standard `wrangler` CLI for one job: ship a built workbook (`dist/<slug>.html`) to Cloudflare Pages on the user's own Cloudflare account. `wb forge web --to cloudflare` drives it through the deploy recipe.

## When to reach for it

Reach for `wrangler` when you want to host a forged workbook on Cloudflare Pages with a single browser login. For a full Cloudflare backend (D1 + Workers AI + auth, not just hosting), reach for the `cloudflare` toolkit instead — `wrangler` here is the one-shot Pages deploy.

## Example

```
wrangler login
wb forge web --to cloudflare      # ship dist/<slug>.html to Cloudflare Pages
```

## What it grants

- One-command static deploy of a built workbook to your own Cloudflare Pages.
- Auth via wrangler's own browser login — the OAuth token lives in `~/.wrangler`, never anything Workbooks stores or proxies.

## Maturity

Experimental (v0.1.0). Requires wrangler 3+. `wrangler --help` and `wrangler pages deploy --help` remain authoritative for per-flag detail.
