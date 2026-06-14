# wrangler

A wrapper around the standard `wrangler` CLI for one job: ship a built workbook (`dist/<slug>.html`) to Cloudflare Pages on the user's own Cloudflare account, via raw `wrangler pages deploy`.

## When to reach for it

Reach for `wrangler` when you want to host a forged workbook on Cloudflare Pages with a single browser login. For a full Cloudflare backend (D1 + Workers AI + auth, not just hosting), reach for the `cloudflare` toolkit instead — `wrangler` here is the one-shot Pages deploy.

## Example

```
wrangler login                                          # browser OAuth, once
mkdir -p site && cp dist/<slug>.html site/index.html    # stage as index.html
wrangler pages deploy site --project-name <slug> --commit-dirty=true
```

## What it grants

- One-command static deploy of a built workbook to your own Cloudflare Pages.
- Auth via wrangler's own browser login — the OAuth token lives in `~/.wrangler`, never anything Workbooks stores or proxies.

## Maturity

Experimental (v0.1.0). Requires wrangler 3+. `wrangler --help` and `wrangler pages deploy --help` remain authoritative for per-flag detail.
