# HTTP route tables — both planes

Two SEPARATE HTTP listeners, never blended:

- **Control plane** (`Workbooks.Web`) — authed, owns every write. Opt-in via
  `WB_WEB=1`; default port 4000. Auth is `Workbooks.Auth` on **every** route
  except the public allowlist.
- **Content plane** (`Workbooks.PublicWeb`) — anonymous, GET-only, serves
  published bytes. Opt-in via `WB_PUBLIC=1`; default port 4001 (TLS variant via
  `WB_PUBLIC_TLS=1`). It has **no `Workbooks.Auth` plug and no write routes** by
  construction.

TOC: auth ladder · public allowlist · content plane · control plane (core, runs,
CTK, brandnana, library/storage, RCP toolkit/kernel, identity/source, query/misc)

## Auth ladder (control plane), first match wins

1. **Public allowlist** — always open: `/health`,
   `/.well-known/workbooks-runtime`, `/.well-known/did.json`.
2. **Desktop per-boot token** — when `WB_DESKTOP=1`, the discovery-file token.
3. **Shared-secret bearer** — `WB_PUBLIC_BEARER` set → `Authorization: Bearer
   <WB_PUBLIC_BEARER>`; tenant from `WB_TENANT`. Any other/absent bearer → 401,
   no dev fallback (locked cloud deploys).
4. **BetterAuth/Guardian JWT** — production multi-tenant path.
5. **`x-tenant` dev header** — only when NOT locked and NOT multi-tenant.

Errors use a single `Workbooks.Web.Error` envelope (`:unauthorized`,
`:tenant_required`, `:not_found`, …).

## Content plane (`Workbooks.PublicWeb`) — anonymous, GET-only

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | liveness → `ok` |
| GET | `/_changes` | the app's public git change feed (newest 30) + keeper status |
| GET | `/_activity` | keeper status + tail of agent step telemetry + a narration line (follow-along) |
| GET | `/*` (glob) | serve the host's published app (the first DNS label is the app id) |

Every response carries `x-served-by: workbooks-runtime`. Non-GET falls through to 404.

## Control plane (`Workbooks.Web`) — authed unless noted

### Core / kernel

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/health` | public | liveness |
| GET | `/.well-known/workbooks-runtime` | public | RCP capabilities handshake (auth rung + feature surface) |
| POST | `/rcp/key/:key_id` | authed | sealed-bundle content-key release (fail-closed, identity-gated) |
| POST | `/oql/parse` | authed | parse Org through the OQL kernel → headlines |
| POST | `/api/workflow` | authed | run the workflows in an Org source; `?plan=1` returns the schedule only |
| POST | `/api/workflow/todo` | authed | run a native org TODO outline as a workflow (async; poll `/api/brand-book/<slug>`) |
| GET | `/docs` | authed | the document viewer (Google-Docs-style reader) |

### Workbook instances

| Method | Path | Purpose |
|---|---|---|
| GET | `/instances` | list registered instances for the tenant |
| PUT | `/w/:id` | deploy a workbook — store its Org source under `:id` |
| GET | `/w/:id` | serve a workbook as a webpage (renders stored Org, or a sample) |
| POST | `/w/:id/call` | the workbook backend — the served page calls home (the Dock) |
| GET | `/w/:id/ws` | upgrade to a WebSocket bridge to the workbook |
| GET | `/api/workbooks` | list workbooks |
| GET | `/api/w/:id/org` | the raw stored Org |
| GET | `/api/w/:id/html` | server-rendered HTML (orgize in the kernel) |

### Agent runs

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/run` | start a long-horizon agent run (returns immediately) |
| GET | `/api/run/:id/stream` | live per-tool-step telemetry stream |
| GET | `/api/run/:id` | poll a run's status + result + observable `events.org` |

### CTK (human-in-the-loop)

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/ctk/commit` | a human commits a review for `?run=<id>` |
| GET | `/api/ctk/review/:id` | the agent polls to receive a pending review (204 when none yet) |
| GET | `/ctk`, `/ctk/*glob` | serve the CTK render toolkit shell + stories from the toolkits root |

### Brandnana pipeline

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/run-brand-book` | run the full brand-book pipeline for a domain (async; poll `/api/brand-book/:slug`) |
| POST | `/api/brandnana-ask` | free-form: the agent drives the brandnana toolkit to a queryable deck |
| GET | `/api/brand-book/:slug` | poll a brand-book run — stage + published deck URL |
| GET | `/api/telemetry/:slug` | one run's task states + tool-call count + time + errors |

### Library / storage (RCP)

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/library/:tenant` | the tenant's access graph — workspaces + members |
| POST | `/api/library/:tenant/query` | cross-workbook OQL query across members |
| POST | `/rcp/build` | `work build` — compile a workspace's components → WASM |
| POST | `/rcp/library/checkout` | borrow a member out (zip back to the caller) |
| POST | `/rcp/library/checkin` | accept a zip and write a member back |
| GET / POST | `/rcp/store` | `work stored` (list keys) / `work store` (archive a workspace) |
| GET | `/rcp/fetch` | `work fetch` — restore stored bytes (base64) |

### RCP toolkit / kernel

| Method | Path | Purpose |
|---|---|---|
| GET | `/rcp/toolkit` | list toolkits |
| GET | `/rcp/toolkit/show` | manifest + skill index (`?id=`, `&skill=`) |
| GET | `/rcp/toolkit/search` | substring search (`?q=`) |
| POST | `/rcp/toolkit/verify` | structural + satisfiability checks (`?id=`) |
| POST | `/rcp/toolkit/eval` | run the toolkit's eval suite server-side (NIFs+LLM here) |
| POST | `/rcp/toolkit/build` | build `#+BUILD_SRC` → register (`?id=`, `&which=`) |
| POST | `/rcp/toolkit/sign` | sign a toolkit with the tenant's did:key |
| POST | `/rcp/toolkit/install` | `work toolkit push` — install a toolkit directory (zip b64, zip-slip-guarded) |
| POST | `/rcp/toolkit/run` | run a skill's `:role task` block |
| POST | `/rcp/kernel/run` | one-shot open/call/close of a kernel-shape toolkit |
| GET | `/rcp/changes` | the tenant repo's public git log, newest first |

### Identity / source rail

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/.well-known/did.json` | public | the engine's did:web identity document |
| POST | `/api/radicle/:tenant/publish` | authed | federate the tenant repo over Radicle → `rad:` id |
| POST | `/api/mirror/:tenant` | authed | mirror the tenant repo to a git host / auto-provision a forge |
| GET | `/api/ledger/:slug` | authed | verify a run's ledger (tamper-evidence + attribution) |

### Query / cross-session

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/search/:tenant` | semantic ∪ literal query (`{query, mode, workbook}`) |
| GET | `/api/telemetry` | cross-session index — every run, newest first, rolled up |
| POST | `/api/browse` | browse/crawl/search through the configured provider |

### Example

```
curl -s http://127.0.0.1:4000/.well-known/workbooks-runtime          # public handshake
curl -s -H "Authorization: Bearer $WB_TOKEN" \
     http://127.0.0.1:4000/api/workbooks                             # authed read
```
