# Deploy a workbook to Cloudflare Pages
## Ship a built workbook .html to Pages on the user's own account, with the real wrangler CLI.

# When to use

The user wants their workbook live on the web at a real URL, hosted on *their
own* Cloudflare account (not our broker / Live URL). One static file, no
server. Preferred over `wb publish` when they want to own the hosting + the
bill and keep the artifact entirely on their infrastructure.

# Workflow

Use the real `wrangler` CLI directly (you, the agent, run it via bash). There is
no `wb forge web` command — that wrapper was removed with the Rust `wb`
(2026-06-09); `wrangler` is the tool. If the user isn't signed in, =wrangler
login= opens the browser; they just authenticate there.

```bash
# build the workbook if you haven't (emits dist/<slug>.html)
wb build

# one-time per machine: browser OAuth into the USER'S Cloudflare account
wrangler login                       # check with: wrangler whoami

# stage a lone .html as index.html so it serves at /, then deploy to Pages.
# the project is auto-created on first deploy; name must be [a-z0-9-] only.
mkdir -p site && cp dist/<slug>.html site/index.html
wrangler pages deploy site --project-name <slug> --branch main --commit-dirty=true
```

On success wrangler prints the live `https://<project>.pages.dev` URL (and a
per-deployment preview URL).

# Auth — we set up THEIR CLI, we never hold the token

`wrangler login` opens a browser and signs into the *user's* Cloudflare
account. The OAuth token is stored by wrangler in `~/.wrangler` — Workbooks
never reads, stores, or proxies it. There is no Workbooks OAuth in this path.
Check status any time with `wrangler whoami`.

# Common pitfalls

- *Project name rules*: Cloudflare Pages project names are `[a-z0-9-]` only —
  lowercase the file stem and replace other chars with '-' when you pass
  `--project-name`.
- *Single file vs dir*: a lone `.html` must be staged as `index.html` so it
  serves at `/` (as above). If you deploy a directory, make sure it contains an
  `index.html`.
- *Dirty git tree*: wrangler refuses a deploy from a dirty tree unless you pass
  =--commit-dirty=true=.
- *Multiple accounts*: if `wrangler whoami` shows more than one account,
  wrangler can't pick non-interactively — set `CLOUDFLARE_ACCOUNT_ID` to the
  32-char hex id of the one you want.
- *First deploy is slower*: the project is auto-created on first
  `pages deploy`; subsequent deploys are incremental + fast.

# Verification checklist

- `wrangler whoami` shows the expected account/email.
- The printed `*.pages.dev` URL returns 200 and renders the workbook.
- For a workbook that needs the WASM runtime, confirm it boots in the hosted
  page (Pages serves the inlined bundle as-is — no extra build step needed).

# See also

- `wrangler pages deploy --help` — authoritative flag reference.
- `toolkits/wrangler/deploy/cloudflare.sh` — an optional helper that stages +
  resolves the account for you (set WB_FORGE_ARTIFACT / WB_FORGE_PROJECT and run
  it directly); the raw commands above are the simplest path.
