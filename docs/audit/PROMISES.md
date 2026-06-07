# BRANDNANA — Promises & Completeness

> Audit date: 2026-06-03. Scope: `projects/brandnana` (Cloudflare Worker `brandnana-api`,
> the `brandnana` CLI toolkit, and the `brandnana-strategist` Fly agent that consumes the
> Workbooks runtime). Worker live at `https://api.brandnana.net`.
>
> This document grades each user-facing promise against the code that is supposed to keep it,
> with `file:line` evidence, and defines the exact conditions under which we would call the
> brandnana substrate "complete."

---

## 1. What Brandnana promises a user

A customer picks brandnana for an end-to-end "give me a brand, get its whole identity and a
finished brand book" pipeline. The advertised promise chain is:

- **P1 — Resolve a brand.** Give a domain or name; get the canonical brand resolved.
- **P2 — Full brand identity.** Logo, color palette, fonts, and brand voice extracted from the
  live site.
- **P3 — Social intelligence.** Profiles, posts, and metrics across ~20 platforms
  (Instagram, TikTok, YouTube, LinkedIn, X, Reddit, Pinterest, Threads, etc.).
- **P4 — Ads intelligence.** Discover and inspect a brand's live ads across Meta, Google, and
  public ad libraries.
- **P5 — Product catalog.** Crawl the brand's full product catalog (every SKU, category,
  collection, price band).
- **P6 — Design tokens.** Turn the identity into a reusable design-token set / styleguide.
- **P7 — One-shot 42-page brand book.** A single command produces a complete, polished,
  wb-compatible 42-page brand book.
- **P8 — A brand-aware agent.** A strategist agent that can answer questions about any brand
  book it (or the workspace) has produced, do competitor analysis, and run fresh research.

---

## 2. Promise-by-promise state

Legend: ✅ works · ⚠️ degraded (works but with a silent fallback or material gap) · ❌ not built.

### P1 — Resolve a brand — ✅ works
- **State:** The `brand fetch <domain>` path is live. Brand retrieval (`retrieveBrand`) backs
  resolve, book, and the brand surface (`book/pipeline.ts:485,515`). The keyless Shopify probe
  + context.dev path resolve real brands; live smoke against the social surface confirmed the
  worker is up and bearer-gated.
- **Gap:** `isShopify()` swallows **all** probe errors to `false`
  (`apps/api/src/catalog/shopify.ts:136-148`, 4s timeout at `:139`), so a transient 429 on a
  genuine Shopify store silently demotes resolution to the inferior context-dev path
  (`apps/api/src/catalog/routes.ts:53-58`). Resolution succeeds but can quietly pick the weaker
  source. Low-severity but real.

### P2 — Full brand identity (logo / palette / fonts / voice) — ⚠️ degraded
- **Logo — ⚠️ wired but mis-ordered.** The 5-tier cascade in
  `apps/api/src/agent/logo-fetch.ts` is genuinely wired and **fails loud** (every candidate is
  validated HTTP-200 + `image/*` + ≥512 bytes; exhaustion returns `result:null` with a populated
  `attempts[]`, callers surface `error`/`missing`). However the cascade tries **Clearbit first
  unconditionally** (`logo-fetch.ts:89`) and context.dev only second
  (`logo-fetch.ts:93-98`), so the paid/preferred context.dev tier is never reached when Clearbit
  serves a hit — a quality/ordering bug, not a silent break.
- **Palette / fonts / voice — ⚠️ works but degrades silently.** Extraction runs through the
  brand-fetch + scrape tiers, but the premium **browser-rendering tier is broken**: 
  `fetch-brand.ts:137-138` dynamically imports `@cloudflare/puppeteer`, which is **not a
  dependency of the API worker** (`apps/api/package.json:14-22` lists no puppeteer), so the
  import throws at runtime; the throw is swallowed at `fetch-brand.ts:165-168` and the function
  silently falls through to context-dev/firecrawl returning `ok:true` from a different/paid
  source. Sibling callers `homepage-scrape.ts:186` and `multipage-text.ts:192` POST to a
  **fictional endpoint** `https://browser-rendering.cf/v1/content` and degrade to stub HTML on
  failure. Vision style-signal routes via OpenRouter (`vision-verify.ts:19`,
  `google/gemini-3.5-flash`) and returns `null` silently if the call throws
  (`vision-verify.ts:64,132,140,150`).
- **Gap:** brand identity is delivered, but the highest-fidelity render path is dead and its
  failure is invisible to the caller. `GOOGLE_API_KEY` is **not** used (the env.ts:51-54 /
  pipeline.ts:626 comments claiming Gemini-via-Google-key are stale — vision is OpenRouter).

### P3 — Social intelligence — ✅ works (live-verified)
- **State:** All 98 `/social/*` verbs route through one helper `get<T>()` in
  `apps/api/src/scrape/social.ts`, backed by `SCRAPECREATORS_API_KEY` (**set in prod**). Live
  smoke: `GET /social/instagram/nike` → 200 with a real normalized summary (291M followers,
  `social/routes.ts:90-98`); `GET /social/instagram/cocacola` → 502 `upstream_unavailable`
  (transient), proving graceful degradation. The 502-not-503 on a degraded handle confirms the
  key is set.
- **Gap (minor):** the `/social/*` surface fails loud, but the **same wrappers** are consumed by
  `/brief`, `/ads/search`, and `/book` where the `null` contract is silently swallowed into
  empty `200`s with an empty `errors[]` (`brief/routes.ts:81-92,356-360`,
  `ads/routes.ts:90,118`, `book/pipeline.ts:256,282`). Also 9 social verbs have a `cliCommand`
  the CLI never registers (`verbs.ts:726,817,828,875,944,1005`) — MCP-callable but shell-unknown.

### P4 — Ads intelligence — ⚠️ degraded (one live leg, one honest-deferred leg, one silently-dead leg)
- **Meta ad-library via scrapecreators — ⚠️ wired-but-fails-silent.** `metaAdLibrarySearch`
  (`scrapecreators.ts:89`) is live with the key set, but only fires when a `brand` param is
  supplied (`ads/routes.ts:98`); every failure mode (missing key / non-2xx / bad JSON) collapses
  to `ads:[]` via two stacked swallow layers (`scrapecreators.ts:30,46,105`,
  `ads/routes.ts:118`) — indistinguishable from "brand has zero ads."
- **Meta Graph API — honest-deferred.** `ads.sync` / `ads.meta.accounts` / `ads.meta.library`
  fail **loud** (502 `meta_error` / 503 `ad_library_not_approved` with actionable guidance,
  `meta.ts` + `ads/routes.ts:171-244`). `META_*` absent by design.
- **Exa discovery leg — ❌ silently dead.** `exaSearch()` throws when `EXA_API_KEY` is absent
  (`scrape/exa.ts:37-39`); in `ads.search` the throw is swallowed by `.catch(() => [])`
  (`ads/routes.ts:90`). Live `POST /ads/search {source:"all"}` returns `200 {count:0, ads:[]}`
  with **zero signal** the primary discovery surface is dead. EXA is intentionally absent
  (Valyu replacement) but the code was never repointed; `VALYU_API_KEY` is set in prod with
  **zero consumers**.
- **Google ads transparency — ✅ wired** via scrapecreators + firecrawl (both set); the Exa
  fallback in `google_ads.ts:70` is dead but harmless (surfaces as a loud 502, not a silent
  empty).
- **Catalog drift:** `auth.connect.meta`, `auth.connect.tiktok`, and `auth.connect.google` all
  declare `httpPath:"/auth/meta"` (`verbs.ts:51,63,74`) — copy-paste with no provider
  discriminator.

### P5 — Product catalog — ❌ not built (in the book path) / ⚠️ partial (standalone crawl)
- **State:** The standalone `POST /catalog/crawl` Shopify/context-dev crawler is real
  (`catalog/shopify.ts`, full paginated catalog at 250/page × up to 200 pages). **But the book
  pipeline never calls it** — `fetchCatalogData` is a **hardcoded zero-stub**: it always returns
  `product_count: 0`, still charges `$0.001`, and emits a **green** `catalog.crawl status:"ok"`
  event (`book/pipeline.ts:336-364`, verified at `pipeline.ts:334-363`; `vendorToSeedShape`
  hardcodes empty products at `:930`).
- **Gap:** every book ships "Catalog: 0 products" while reporting success. `SKILL.md` still
  advertises product counts / OQL queries (`skill-md.ts:106,120,132`). The verb catalog omits
  `shopify` from `catalog.crawl` vendors entirely (`verbs.ts:325` lists only
  `["context-dev","openrouter"]`) despite Shopify being the preferred auto path.

### P6 — Design tokens / styleguide — ⚠️ degraded
- **State:** `brand.styleguide` / `brand.screenshot` verbs exist in the catalog
  (`verbs.ts:130,158`) and the brand-fetch `include=fonts,screenshot,styleguide` extras path is
  the real surface (`verbs.ts:100-112`).
- **Gap:** Those two verbs (plus `catalog.status` and 6 social verbs) have a `cliCommand` the
  CLI never registers (toolkit finding, high severity) — MCP-callable but invisible to the shell.
  Token quality is also bounded by the broken render tier (P2). Functional but not first-class.

### P7 — One-shot 42-page brand book — ❌ not built (as promised)
- **State:** The pipeline produces a **deck of at most 11 slides**, not a 42-page book.
  `presentation-shell.ts:5` literally says "10-slide brand book"; the `BUILDERS` map has 11 keys
  gated by `curate.ts` `ALL_SLIDES` (11), fallback 10. `document-shell.ts renderDocument` (the
  long-form renderer) is used **only** by `agent/executor.ts`, never by the book pipeline.
- **wb runtime never invoked.** `book-bundle.ts:1-9` ports minimal bundling by hand and never
  shells out to `wb build`/`unbundle`/`preview`. Worse, the bundle **omits `data-version`**, and
  forge `unbundle.mjs:38-43` hard-fails unless `data-version === 1` — so **`wb unbundle` rejects
  every book brandnana emits** (`presentation-shell.ts:209`, `book-bundle.ts:57`).
- **Filename / metadata drift.** Catalog + extractor read org props the templates never emit
  (`extract-metadata.ts:181-238` vs `templates.ts:14-23,128`); `verbs.ts:1559` says
  `slug.workbook.html` but the pipeline writes `slug.html` (`pipeline.ts:794,1125`).
- **Gap:** the headline "42-page brand book" is currently a ≤11-slide static template that wb
  itself cannot round-trip. This is the single biggest promise gap.

### P8 — Brand-aware agent (query books, competitors, research) — ❌ not built / non-functional
- **State:** The `brandnana-strategist` Fly agent is **non-functional across all three core
  capabilities** at the deploy layer (see §3). Even ignoring deploy gaps, the worker provides
  **no server route to query saved books** (book query is CLI-local only, `cli book.ts:599`),
  and the agent's `ads_search` / `catalog_crawl` executor verbs are **hardcoded `status:"skipped"`**
  (`executor.ts:87-91`). Competitor "analysis" is just homepage + logo scrape.
- **Gap:** the promise that the agent "can answer questions about any brand book or workspace
  data" has no backing query surface, no working CLI/runtime, and no scrubbed secrets reaching
  agent bash. Effectively unbuilt.

---

## 3. What the agent is supposed to do that it can't yet

The `brandnana-strategist` substrate (Fly machine consuming the Workbooks Elixir runtime) is
designed to: resolve brands via `brandnana` verbs, build/publish a workbook via `wb`, and
**query existing brand books + workspace data**. Today it can do **none** of these:

- **Query existing brand books / workspace-data Q&A — BLOCKER.** The only mechanism is
  `wb workbooks query` → `POST /api/workbook/query`, which needs the Workhorse daemon discovery
  file (`listen.json`) or `WB_DAEMON_URL`/`WB_DAEMON_TOKEN`. The cloud runtime writes **none** of
  these (only the desktop Tauri sidecar writes `listen.json`;
  `services/brandnana-agent/entrypoint.sh` sets no `WB_DAEMON_*`). Every daemon-backed `wb`
  command fails at `connect()` (`cli/wb/src/daemon.rs:23-64`,
  `cmd/workbooks_query.rs:14`). There is **no server route to query saved books** at all.
- **Run any `brandnana` verb / build any `wb` workbook — BLOCKER.** Neither the `brandnana`
  binary, the `wb` binary, `node`, nor `jq` is installed in the Fly image
  (`services/brandnana-agent/Dockerfile:67-103`). Every verb and every `wb build`/`publish`
  fails command-not-found.
- **Authenticate to the API at all — BLOCKER.** `BRANDNANA_API_KEY` and `OPENROUTER_API_KEY` are
  scrubbed by the runtime secret blocklist before reaching agent bash because
  `WB_FORWARD_SECRETS` is never set on this service
  (`tool_registry.ex:166,194-218`; manifest assumes the allowlist at
  `toolkits/brandnana/manifest.org:30`). Every call 401s.
- **Competitor analysis — not built.** Reduced to homepage + logo scrape; the discovery /
  ads legs are skipped or silently empty (`executor.ts:79-91`).
- **Valyu-powered research — not built.** `VALYU_API_KEY` is set in prod with **zero code
  consumers** (grep `valyu` = 0 hits). Search/discovery still targets Exa (`scrape/exa.ts`),
  which is intentionally absent — so research returns empty. Migration not started.
- **Company firmographics via `THE_COMPANIES_API_KEY` — not built.** Set in prod, **zero
  consumers** (grep `thecompanies`/`companies` = 0). No enrichment exists anywhere.
- **WorkOS auth — not built.** `WORKOS_API_KEY` / `WORKOS_CLIENT_ID` set in prod, **zero
  consumers**; auth is still 100% Clerk (and the Clerk path does not even verify JWT signatures —
  `portal-keys.ts:80-87` decodes with `atob`, no JWKS — a separate security finding).
- **Groq LLM — not built in the worker.** `GROQ_API_KEY` set in prod, consumed **only** by the
  local CLI (`apps/cli/src/commands/logo.ts:519`); the worker's CF-AI-Gateway module that lists
  `groq` is dead code (`gateway.ts:31`, zero callers).

**Orphan-key summary (set in prod, zero worker consumers):** `VALYU_API_KEY`,
`WORKOS_API_KEY`, `WORKOS_CLIENT_ID`, `THE_COMPANIES_API_KEY`, `GROQ_API_KEY` (worker).
Each must be either wired to its intended consumer or removed.

---

## 4. Definition of Done / completeness checklist

The brandnana substrate is **complete** when every item below is true and the end-to-end
acceptance test passes with **every vendor leg green** (no silent empties, no swallowed throws).

### Worker / contract
- [ ] **P5 catalog wired:** `book/pipeline.ts fetchCatalogData` calls the real
      Shopify/context-dev crawler; a book for a real Shopify store reports `product_count > 0`;
      `catalog.crawl` no longer emits a green `ok` event on a zero stub.
- [ ] **P4 discovery repointed:** Exa replaced by Valyu (`POST api.valyu.ai/v1/search`,
      `x-api-key`, `search_type:web`, `fast_mode:true`); `ads.search` with `source=all`/no brand
      returns real rows or an explicit `discovery_unavailable` warning — never a silent
      `count:0`. `VALYU_API_KEY` has a consumer.
- [ ] **P2 render reconciled:** the `@cloudflare/puppeteer` import has a backing dependency (or
      is replaced by the real CF browser-rendering REST endpoint); the fictional
      `browser-rendering.cf` host is removed; render failures surface in the response, not just
      `attempts[]`.
- [ ] **P2 logo order fixed:** context.dev tried before Clearbit; favicon/og-image demoted to a
      flagged last-resort `LogoResult.source`.
- [ ] **P7 book is a real 42-page document:** `buildBook` wired to `document-shell.ts`
      (or the deck is re-scoped and the "42-page" claim dropped); the bundle includes
      `data-version`/`root-name`/`file-count` so **`wb unbundle` accepts it**; a CI test runs
      `wb unbundle` then `wb build` on a produced book and passes.
- [ ] **P8 server book-query route exists:** a bearer-gated worker route lists/queries saved
      brand books (so the agent does not depend on the desktop daemon), with a corresponding
      `book.*` verb in `verbs.ts`.
- [ ] **Catalog ↔ route ↔ CLI ↔ MCP parity:** the 9 verbs with unregistered CLI commands are
      registered (or removed); the two live-but-uncatalogued route families
      (`/v1/book/seed*`, `/v1/agent`, `/scrape`, `/v1/skills`) get VERBS entries or are removed.
- [ ] **Secret hygiene:** every orphan key (`VALYU`, `WORKOS_*`, `THE_COMPANIES`, `GROQ`) is
      either wired to a consumer or deleted; `env.ts` Bindings + `/health` `secretKeys` list
      reflect prod reality (add `CEREBRAS`/`CLERK`; drop `EXA`/`E2B`/`GOOGLE`/`CF_AI_GATEWAY`);
      stale `GOOGLE_API_KEY` and `E2B` declarations removed.
- [ ] **Typechecks + smoke green:** `tsc --noEmit` passes (currently 11 api + 8 cli errors); the
      nightly smoke test no longer hard-requires absent `EXA`/`CF_AI_GATEWAY_TOKEN`
      (`test/smoke.ts:66-72`) and goes green.

### Agent / substrate
- [ ] **Image is runnable:** `wb` (+ bundled forge), `brandnana`, `node`, `jq` installed in the
      Fly image and on `PATH` (under whatever `workbox_bin_path()` resolves to); Docker build has
      a `wb --help` / `brandnana --help` smoke step.
- [ ] **Secrets forwarded:** `WB_FORWARD_SECRETS="BRANDNANA_API_KEY OPENROUTER_API_KEY"` set so
      they survive the runtime blocklist; boot asserts each needed key is present.
- [ ] **Query contract live:** the cloud runtime writes a loopback `listen.json` (or
      `entrypoint.sh` exports `WB_DAEMON_URL`/`WB_DAEMON_TOKEN`) so `wb workbooks query` connects.
- [ ] **Memory round-trips:** `WB_MEMORY_ROOT`/`OQL_QUERY_ROOT` aligned to
      `$WB_DATA_ROOT/Engine/memory`, and the `wb` writer layout reconciled with the engine's flat
      `<tier>.org`; `wb memory remember` accepts the key/value form the skills use.
- [ ] **Single profile source of truth:** delete `services/brandnana-agent/profile` (stale
      2026-05-29) or sync from canonical `substrates/brandnana/profile` (2026-06-03) with CI
      drift-fail; shipped skills stop curling non-existent `/v1/scrape/homepage`, `/v1/logo`,
      `/v1/screenshot`, `/v1/verify-brand`, `/v1/multipage` endpoints.

### End-to-end acceptance test (the proof)

A single CI/eval run, against the live worker + a freshly built agent image, must pass:

1. **Resolve:** `brandnana brand fetch <real-shopify-domain> --json` returns a brand with a
   real logo (context.dev-sourced), palette, and fonts — render tier green (no swallowed
   `browser_error` in `attempts[]`).
2. **Social + ads:** `brandnana social instagram <handle>` returns a real summary; 
   `brandnana ads search --brand <brand> --source all` returns a non-empty result OR an explicit
   `discovery_unavailable` warning (never a silent `count:0`), with the Valyu leg green.
3. **Catalog:** the brand book for that domain reports `product_count > 0` (real crawl, not the
   zero stub).
4. **Book:** the produced `slug.workbook.html` passes `wb unbundle` then `wb build` with no
   errors, and is a full-length document (or the re-scoped page count is honestly reflected
   everywhere).
5. **Agent query:** from inside the agent container, `wb workbooks query "<books-glob>" "<expr>"`
   returns the just-built book's data, and the strategist answers a natural-language question
   about it (e.g. "what palette did we pick for X and how does it compare to competitor Y").
6. **Vendor ledger:** every leg (brand, social, ads-Valyu, catalog, book, query) records cost in
   the brandnana ledger and `/health` reports every consumed secret as present.

When steps 1–6 pass in one run with no silent-empty / swallowed-throw paths, the substrate is
complete.
