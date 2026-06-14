# railway

A wrapper around the standard `railway` CLI for one job: publish a built workbook (`dist/<slug>.html`) as a static site on the user's own Railway account. Stage the artifact behind a small Caddy image that listens on Railway's `$PORT`, then `railway up`.

## When to reach for it

Reach for `railway` when you want to host a forged workbook as a static site on your own Railway account. Auth is Railway's own browser login — the token lives in `~/.railway`, never anything Workbooks stores.

## Example

```
railway login                                   # browser OAuth, once
railway init --name <slug>                       # link a project
mkdir -p site && cp dist/<slug>.html site/index.html   # + a Caddy Dockerfile binding $PORT
railway up                                       # build the image + deploy
```

## What it grants

- One-command static-site deploy of a built workbook to your own Railway account.
- A generated Caddy image that serves the `.html` on Railway's assigned `$PORT`.

## Maturity

Experimental (v0.1.0). Requires railway 3+. `railway --help` and the Railway CLI docs are authoritative for per-command detail.
