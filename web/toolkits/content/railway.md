# railway

A wrapper around the standard `railway` CLI for one job: publish a built workbook (`dist/<slug>.html`) as a static site on the user's own Railway account. `wb forge web --to railway` drives it through the deploy recipe, staging the artifact behind a generated Caddy image that listens on Railway's `$PORT`, then running `railway up`.

## When to reach for it

Reach for `railway` when you want to host a forged workbook as a static site on your own Railway account. Auth is Railway's own browser login — the token lives in `~/.railway`, never anything Workbooks stores.

## Example

```
railway login
wb forge web --to railway       # stage dist/<slug>.html behind Caddy, railway up
```

## What it grants

- One-command static-site deploy of a built workbook to your own Railway account.
- A generated Caddy image that serves the `.html` on Railway's assigned `$PORT`.

## Maturity

Experimental (v0.1.0). Requires railway 3+. `railway --help` and the Railway CLI docs are authoritative for per-command detail.
