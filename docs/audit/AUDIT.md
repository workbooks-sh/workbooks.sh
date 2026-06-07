# BRANDNANA — Master Wiring Audit

**Scope:** brandnana product (Cloudflare Worker API + `brandnana` CLI toolkit + brandnana-strategist agent), as a consumer of the Workbooks Elixir runtime.
**Repo root:** `/Users/shinyobjectz/Apps/workbooks` · **Product:** `projects/brandnana` · **Canonical contract:** `projects/brandnana/packages/schema/src/verbs.ts` (the `VERBS` catalog).
**Method:** static trace of catalog → routes → toolkit/CLI → docs, plus an adversarial verification pass on every "wired" vendor claim and a small set of live smoke calls against `https://api.brandnana.net`.
**Date:** 2026-06-03.

All paths below are relative to `projects/brandnana/` unless prefixed otherwise. Citations are `file:line`.

---

## 1. Executive Summary

Severity-ranked, the findings that matter most:

1. **`blocker` — The brandnana-strategist agent is non-functional in the cloud runtime across all three core capabilities.** It cannot run `brandnana` verbs (binary never installed, `BRANDNANA_API_KEY` scrubbed before agent bash because `WB_FORWARD_SECRETS` is never set), cannot run `wb build`/`wb publish` (`wb`/`node` not in the image), and cannot query saved brand books or workspace data (`wb workbooks query` needs a Workhorse daemon `listen.json` the cloud engine never writes). See §7. `services/brandnana-agent/Dockerfile:67-103`, `runtime/engine/.../tool_registry.ex:166,194-218`, `cli/wb/src/daemon.rs:23-64`.

2. **`blocker` — The book pipeline cannot produce the advertised deliverable.** The catalog leg is a hardcoded 0-product stub that still emits a green `catalog.crawl status:ok` event and charges `0.001` (`book/pipeline.ts:334-364,930`); the "42-page book" is at most an 11-slide deck (`presentation-shell.ts:5`, `curate.ts:20-32`); the `wb` runtime is never invoked (`book-bundle.ts:1-9`); and the emitted bundle omits `data-version`, so `wb unbundle` rejects every book (`presentation-shell.ts:209` vs forge `unbundle.mjs:38-43`). See §6.

3. **`high` — Clerk auth verification is bypassable (forged-token auth bypass).** `verifySessionJwt` decodes the JWT payload with plain `atob` and never checks the signature; the only Clerk-backend session check is gated behind `if (payload.sid)`, and the user is then fetched with the server's own `CLERK_SECRET_KEY`. A forged/unsigned JWT with a valid `sub` and no `sid` mints a live `adk_live_*` key bound to the victim's account. `auth/portal-keys.ts:80-87,92-106,174`; `auth/cli-flow.ts:48-54,62-65,185-197`. The doc comment claiming JWKS verification (`portal-keys.ts:9`) is contradicted by the code (`:21`). See §4.

4. **`high` — Silent-fallback bugs confirmed by the adversarial pass ("looks wired but isn't"):**
   - **`ads.search` Exa leg returns empty-but-200.** `exaSearch()` throws when `EXA_API_KEY` is absent (prod reality), but the throw is swallowed by a bare `.catch(() => [])` (`ads/routes.ts:90`) — no log, no warning, no degraded flag. Live `POST /ads/search {source:"all"}` returned `200 {count:0,ads:[]}`. The primary discovery surface is dead and the caller is never told. See §4.
   - **`browser-rendering` is broken AND silent.** `@cloudflare/puppeteer` is not a dependency of the brandnana worker (`apps/api/package.json:14-22`), so the dynamic import at `scrape/fetch-brand.ts:137-138` throws at runtime; the throw is swallowed (`:165-168`) and `fetchBrand` silently falls through to a different paid tier returning `ok:true`. Two sibling callers also POST a fictional host `https://browser-rendering.cf/v1/content` (`homepage-scrape.ts:186`, `multipage-text.ts:192`). See §4.
   - **Shopify catalog mis-routing.** `isShopify()` swallows every probe failure (timeout, 429, challenge) to `false` (`catalog/shopify.ts:136-148`), so a transient failure silently demotes a real Shopify store to the 12-product context.dev path (`catalog/routes.ts:53-58`, `catalog/context.ts:44-46`). A caller asking to "crawl every product" silently gets ~12. See §4.

5. **`high`/`medium` — Five ORPHAN prod secrets with ZERO worker consumers.** `GROQ_API_KEY`, `THE_COMPANIES_API_KEY`, `WORKOS_API_KEY`, `WORKOS_CLIENT_ID`, `VALYU_API_KEY` are all SET in prod but `grep` across `apps/api/src` + `packages` finds no reader for any of them, and none are even declared in `env.ts` `Bindings`. `GROQ_API_KEY` is consumed only by the local CLI (`apps/cli/src/commands/logo.ts:516,519` via `process.env`) — so the *worker* secret is a true orphan. See §4 and §9.

6. **`high` — Two provider migrations are in flight but the code is NOT repointed.**
   - **Exa → Valyu:** `scrape/exa.ts` still targets `api.exa.ai`; `verbs.ts` still tags `exa` on `ads.search`/discovery verbs (`:221`); `VALYU_API_KEY` has zero consumers. Until repointed, `exa` in the catalog is the live truth and Valyu is dead.
   - **Clerk → WorkOS:** auth is 100% Clerk. `WORKOS_*` have zero TS hits; `apps/portal/package.json:10` declares `@workos/authkit-sveltekit` but nothing imports it. See §4.

7. **`high` — Toolkit↔contract drift: 9 catalog verbs have a `cliCommand` the CLI never registers** (MCP-callable but a shell "unknown command"), e.g. `brand.styleguide`/`brand.screenshot` (`verbs.ts:130,158`), `catalog.status` (`:328`), `social.linkedin.post` (`:726`), `social.youtube.searchHashtag`/`shortsTrending` (`:817,828`), `social.twitter.tweetTranscript` (`:875`), `social.facebook.postComments` (`:944`), `social.reddit.postComments` (`:1005`). MCP exposes all (`mcp.ts:80`). See §5.

8. **`win` — The social/scrapecreators cluster is genuinely WIRED and live-verified.** `SCRAPECREATORS_API_KEY` (set in prod) backs all 98 `/social/*` verbs through one `get()` helper (`scrape/social.ts`). Live: `GET /social/instagram/nike` → `200` with a real normalized summary (nike, 291,995,462 followers); `GET /social/instagram/cocacola` → `502 upstream_unavailable` (transient), proving graceful degradation. The `502` (not `503`) confirms the key is set in prod (`social/routes.ts:57-60`). **Caveat from the adversarial pass:** the `/social/*` surface fails loud, but the SAME null-returning wrappers are swallowed into empty/null `200`s by `/brief`, `/ads/search`, and `/book` (see §4) — so the win is scoped to `/social/*`, not blanket.

> **Not proven / honest gaps:** No live render of the `browser-rendering` tier was attempted with a present binding (it cannot succeed — dead import). The Clerk auth-bypass was confirmed by static reading of the verification path, not by minting a key with a forged token against prod. `wb unbundle` rejection of brandnana books was confirmed against the forge `unbundle.mjs` contract, not by executing `wb` against a produced bundle (the pipeline never runs `wb`).

---

## 2. Architecture Map — Five Layers

| # | Layer | Lives at | Role | Health |
|---|-------|----------|------|--------|
| 1 | **Product API** (Worker) | `apps/api/src` (Hono on Cloudflare) | The ~180-verb HTTP surface; routes mounted in `index.ts`. Consumes all third-party vendors. | Social wired & live; ads/book/catalog have silent-fallback + stub defects; auth-verify bypassable. |
| 2 | **Toolkit** (`brandnana` CLI + MCP) | `apps/cli/src` + toolkit profile | Maps VERBS → shell commands and MCP tools for agents/humans. | 9 verbs MCP-only (no CLI); manifest/skill docs drift from real cascade. |
| 3 | **Substrate agent** (canonical profile) | `substrates/brandnana/profile` (edited 2026-06-03) | Source-of-truth strategist prompt + 5 pipeline skills. | Diverges from shipped copy; intra-pipeline filename drift; `/opt` path tree it cats doesn't exist. |
| 4 | **Agent service** (deployed) | `services/brandnana-agent` (Fly image, profile dated 2026-05-29) | The container that actually runs the strategist. | STALE vs canonical; no sync script; missing binaries/secrets; skills curl non-existent endpoints. |
| 5 | **Runtime** (Workbooks engine) | `/Users/shinyobjectz/Apps/workbooks/runtime/engine` (Elixir) | Hosts the agent, scrubs secrets, brokers `wb`/memory/query. | Functioning, but cloud deploy never starts the daemon or forwards secrets the agent needs. |

The contract (`packages/schema/src/verbs.ts`) is the spine that layers 1–4 are all supposed to agree on. The audit's recurring theme is **drift between this spine and each layer**, plus **swallowed failures inside layer 1**.

---

## 3. Endpoint Inventory & Contract Status

**Catalog size:** ~180 verbs in `verbs.ts` (the social audit counted 125 in one slice header; the social cluster alone is 98). Namespace breakdown of the social/ads region (from `verbs.ts` via `scrape/social.ts`):

| Namespace | Verbs | Backing |
|-----------|-------|---------|
| `social.*` (all platforms) | 98 | `scrapecreators` (single `get()` helper) |
| `ads.*` | 5 | mixed: scrapecreators (meta proxy), firecrawl (google), exa (dead), meta Graph (deferred) |
| `brand.*` | several | context.dev / firecrawl / browser-rendering / logo cascade |
| `catalog.*` | several | shopify (auto) + context.dev |
| `book.*` | `book.build` only in catalog | book pipeline (server-side) |
| `agent.*` | none in catalog | live `/v1/agent` plan→execute path |

Per-platform social counts: tiktok 17, youtube 9, instagram 7, facebook 6, tiktok-shop 5, linkedin 5, twitter 4, twitch 4, reddit 4, pinterest 4, threads/spotify/soundcloud/rumble/bluesky/truthsocial 3 each, snapchat/kick/google-search/instagram-reels-search/links 1 each.

### Contract issues (route-with-no-verb)

| Issue | Path | Detail |
|-------|------|--------|
| `book` seed routes invisible to contract | `book/routes.ts:179-256` | `POST /v1/book/seed/:slug` and `GET /v1/book/seeds` are live bearer-gated handlers with NO `VERBS` entry (only `book.build` covers `POST /v1/book`). |
| Entire `agent` surface absent from contract | `agent/routes.ts:22-123`, mounted `index.ts:160,171,174` | `/v1/agent` (POST plan→execute, `GET /job/:slug`), `/scrape` (`/`,`/exa`,`/firecrawl`), `/v1/skills` (list/bundle/file) have zero `VERBS` entries. The headline free-form "query → plan → execute → answer" capability is **not in the canonical contract**. `/scrape/exa` also calls Exa under the absent `EXA_API_KEY`. |
| `book/publish` + `asset/upload` not in catalog | `verbs.ts` grep = no match | Publish-workbook + make-image skills curl `https://api.brandnana.net/v1/book/publish` and `/v1/asset/upload` (TODO `wb-o2ax`); either un-cataloged routes (route↔catalog drift) or 404s. See §6/§7. |
| `book ls/show/open/query/expand` documented in CLI but absent from catalog | `book.ts:504-632` vs `verbs.ts:1552` | CLI documents book-query subcommands the catalog and MCP don't expose. |

---

## 4. Vendor Wiring Matrix

**TRUE status** reflects the adversarial verdicts, which correct several of the first-pass classifications. Legend: **wired** = real upstream, fails loud; **wired-silent** = real upstream but failures swallowed into success-shaped empties; **broken** = cannot succeed; **orphan-key** = prod secret with no worker consumer; **deferred** = intentionally not built; **stub** = empty implementation.

| Vendor | Env var | #verbs | Prod secret | TRUE status | Failure mode | Recommendation |
|--------|---------|-------:|-------------|-------------|--------------|----------------|
| **scrapecreators** (social) | `SCRAPECREATORS_API_KEY` | 98 | **set** | **wired** (live-verified) — but **wired-silent** when consumed by `/brief`, `/ads/search`, `/book` | `/social/*` correctly returns 503 not_configured / 502 upstream_unavailable (`social/routes.ts:57-60`). Same `null`-returning wrappers (`scrape/social.ts:28,44,47-49`) are swallowed into empty 200s with no `errors[]` by `brief/routes.ts:81-92`, `ads/routes.ts:90,118`, `book/pipeline.ts:256,282`, `google_ads.ts:54`. | None for `/social/*`. Push the null→error contract into `/brief`/`/ads`/`/book` so config/outage isn't rendered as "brand has no presence". Surface `credits_remaining` (`scrapecreators.ts:11` TODO). |
| **exa** (ads discovery) | `EXA_API_KEY` | 2–3 | **missing** (intentional) | **degraded / silent** (not refuted) | `exaSearch()` throws when key absent (`exa.ts:37-39`); swallowed in `ads.search` by `.catch(()=>[])` (`ads/routes.ts:90`) → live `200 {count:0}`. In `google_ads`, the exa call (`google_ads.ts:70`) is OUTSIDE the try/catch and surfaces as a LOUD `502 scrape_failed` (`ads/routes.ts:163-165`) — *correcting* the first-pass "falls to no_match" claim. | Repoint to Valyu `POST api.valyu.ai/v1/search` (`x-api-key`, `search_type:web`, `fast_mode:true`). Until then return a `discovery_unavailable` warning instead of a silent empty array. |
| **meta** (ad-library via scrapecreators proxy) | `SCRAPECREATORS_API_KEY` | 1 | **set** | **wired-silent** (refuted from "wired") | `metaAdLibrarySearch` → `scGet` returns null on missing-key/non-2xx/bad-JSON (`scrapecreators.ts:30,46,47-51`), coalesced to `{ads:[]}` (`:105`), then `.catch(()=>[])` again (`ads/routes.ts:118`). 401/402/429/field-rename all become byte-identical to "brand has zero ads". `searchResults` is hardcoded with no fallback despite a 5-name cursor coalesce (`:108-114`). | Distinguish empty-by-failure from empty-by-truth; emit a warning channel. Only fires when `source∈{meta,all}` AND `brand` supplied (`ads/routes.ts:98`) — document that. |
| **meta** (Graph API: own ads / accounts / official Ad Library) | `META_GRAPH_TOKEN` / `META_CLIENT_*` | 3 | **missing** (deferred) | **deferred — honest** | `resolveMetaToken` returns null → `listMyAds`/`listAdAccounts` THROW (`meta.ts:155-159,206-208`) → `502 meta_error` (`ads/routes.ts:179-181,214-216`). Ad Library detects OAuthException → `503 ad_library_not_approved` with guidance (`meta.ts:278-279`). No silent fallback. | Keep. Ensure CLI surfaces the 502/503 guidance verbatim. |
| **tiktok** (OAuth connect) | `TIKTOK_CLIENT_*` | 1 | **missing** (deferred) | **deferred** | `auth.connect.tiktok` is an OAuth stub whose `httpPath` is literally `/auth/meta` (`verbs.ts:63`), identical to meta/google connect. The ~17 live TikTok *social-scrape* verbs are scrapecreators-backed and fine. | Keep deferred. Fix the catalog copy-paste: carry the provider in path/body. |
| **google** (Ads Transparency scrape + OAuth connect) | `SCRAPECREATORS_API_KEY` + `FIRECRAWL_API_KEY` | 2 | **set** | **wired** (not refuted) | Real pipeline: scrapecreators advertiser search (`google_ads.ts:52-66`) → firecrawl render + creative-id regex (`:115-131`). `no_match` returns truthful warning+nulls (`:99-110`); handler catches throws → `502` (`ads/routes.ts:163-165`). Exa fallback (`:70`) is dead-but-caught. **Caveat:** scrapecreators non-ok/parse-error coalesces to empty (`scrapecreators.ts:46,49,147`), masking outages as `no_match`/misleading 502. | Functional. Repoint exa fallback to Valyu. Distinguish scrapecreators outage from genuine no-match. |
| **shopify** (catalog) | none (keyless `/products.json`) | 1 | n/a | **wired-with-silent-fallback** (refuted from "wired") | Crawl client fails loud (`shopify.ts:119,166-169`). But `isShopify()` swallows ALL probe failures to `false` (`:136-148`, 4s timeout `:139`); auto strategy then routes a transiently-failing real Shopify store to the inferior 12-product context.dev path (`routes.ts:53-58`, `context.ts:44-46`) with no signal. Catalog omits `shopify` from `catalog.crawl` vendors (`verbs.ts:325`). | Retry the `isShopify` probe; distinguish "not Shopify" from "could not tell"; add `shopify` to the catalog vendors. |
| **browser-rendering** | `BROWSER` binding | 1 | n/a | **broken + silent** (refuted from "degraded") | `@cloudflare/puppeteer` is NOT a dep of the worker (`apps/api/package.json:14-22`); dynamic import (`fetch-brand.ts:137-138`) throws at runtime; swallowed (`:165-168`) → silent fall-through to paid context-dev/firecrawl tiers returning `ok:true`. Siblings POST fictional `https://browser-rendering.cf/v1/content` (`homepage-scrape.ts:186`, `multipage-text.ts:192`). Only test asserts the binding-ABSENT fall-through (`fetch-brand.test.ts:145-176`). | Reconcile to one client (`@cloudflare/puppeteer` with the dep added, or the real CF REST API). Make the premium-tier failure visible, not a no-op. |
| **logo-cascade** | `CONTEXT_DEV_API_KEY` (as logoDevToken) | 1 | **set** | **wired** (refuted from "degraded") | 5-tier cascade validates every candidate (200 + `image/*` + ≥512B, `logo-fetch.ts:33-37`), returns `result:null` + populated `attempts[]` on exhaustion (`:121`), and all 5 callers surface failure loudly (executor/dispatcher/pipeline). The only fallback (`pipeline.ts:703`) degrades to the vendor brand-fetch's OWN logo, reported honestly (timeline `status:"missing"`). **Minor:** size floor only applies when `content-length>0` (`:36-37`). | Working. (Note: a *separate* manifest/doc finding claims a Clearbit-first ordering bug — see §5; the cascade-code verdict here is "wired".) |
| **cerebras** | `CEREBRAS_API_KEY` | 3+ | **set** | **wired** (degraded-but-visible) | Client fails loud (`ai.ts:79,110-115,167-171`). `curate.ts` fallbacks are tagged `source:"fallback"` + surfaced in timeline (`pipeline.ts:693-697,992-996`). **Correction:** it IS used by the interactive `/v1/agent` path (`dispatcher.ts:183,237` use Cerebras; executor strategist/composer/planner call `chatJson` on the Cerebras key) — and that path fails loud too (`executor.ts:176-186`). | Add `cerebras` as a vendor token in `verbs.ts`. Reconcile the `env.ts:42-43` "Cerebras direct" comment with the dual-stack reality. |
| **openrouter** | `OPENROUTER_API_KEY` | 4+ | **set** | **wired** | Loud 503 guard (`llm.ts:81`); image-gen throws (`image-gen.ts:52`). Primary for the brand-book composition pipeline (`planner.ts:124`, `strategist.ts:101`, `composer.ts:119`, `writer.ts:103`), image gen, and vision. **One silent path:** vision-verify returns null on missing key (`vision-verify.ts:64`) — optional enrichment, disclosed. **Correction:** OpenRouter is NOT the interactive dispatcher LLM (that's Cerebras). | Consolidate the THREE OpenRouter clients (`llm.ts`, `llm/openrouter.ts`, inline in `vision-verify.ts`/`image-gen.ts`). Fix the `env.ts:41-43` comment claiming OpenRouter is "currently UNUSED". |
| **cf-ai-gateway** | `CF_AI_GATEWAY_TOKEN` | 0 | **missing** (only on old adalign-api) | **broken / dead** | `gateway.ts` (`llmFetch`/`llmBaseUrl`) has ZERO callers — the whole CF AI Gateway module is dead. `llm/openrouter.ts:43-50` `gatewayUrl()` returns null without the token, so every OpenRouter call goes DIRECT despite docstrings claiming proxy/caching. | Delete `gateway.ts` + the misleading docstrings, OR provision the token and route through it. |
| **google-gemini-vision** | `GOOGLE_API_KEY` | 0 | **missing** | **orphan-key / phantom** | `GOOGLE_API_KEY` has ZERO code reads. Vision routes Gemini via OPENROUTER (`vision-verify.ts:19-20,54-64`, model `google/gemini-3.5-flash`). The `env.ts:51-54` + `pipeline.ts:626` comments claiming vision uses `GOOGLE_API_KEY` are STALE/WRONG. | Delete `GOOGLE_API_KEY` from `env.ts` + `/health`; fix the two stale comments (the exact "looks wired but isn't" trap). |
| **clerk** | `CLERK_SECRET_KEY` | 0 (auth) | **set** | **wired-but-broken** (refuted from "wired") | Config guard fails loud (503 `clerk_not_configured`). But `verifySessionJwt` never checks the JWT signature (`portal-keys.ts:80-87`, `cli-flow.ts:48-50`); session check gated on `if(payload.sid)` (`:92`/`:53`); user fetched with server's own key (`:103-106`/`:62-65`) → forged-token key-mint bypass (`:174`/`:185-197`). No `jwks`/`jose`/`@clerk/backend` dep. `_unusedClerkMeVerify` is dead code (`:35,256`). | **Treat as a security defect.** Verify signatures via JWKS (`@clerk/backend`/`jose`); require `sid`; delete dead `/me` verify. |
| **workos** | `WORKOS_API_KEY` / `WORKOS_CLIENT_ID` | 0 | **set** | **orphan-key** | Zero TS hits anywhere. Auth is entirely Clerk. `apps/portal/package.json:10` declares `@workos/authkit-sveltekit` but nothing imports it. Not in `env.ts`. | Start the migration (replace `verifySessionJwt`) OR remove the secrets + unused dep. |
| **valyu** | `VALYU_API_KEY` | 0 | **set** | **orphan-key** | Zero consumers. Search still goes through Exa. Not in `env.ts`. | Wire as the Exa replacement (`POST api.valyu.ai/v1/search`) OR remove the orphan. |
| **groq** | `GROQ_API_KEY` | 0 (worker) | **set** | **orphan-key** (worker) | `gateway.ts:31` only declares a `groq` enum; no worker reads `env.GROQ_API_KEY`. Real consumer is the **local CLI** vision fallback (`logo.ts:516,519`, `logo-tags.ts:101`, `process.env`) running on the user's machine. Not in `env.ts`. | Wire Groq as a worker LLM provider OR drop the worker secret. CLI usage uses the dev's own env. |
| **thecompaniesapi** | `THE_COMPANIES_API_KEY` | 0 | **set** | **orphan-key** | Zero consumers. No firmographic enrichment wired. Not in `env.ts`. | Build a company-enrichment consumer OR delete the secret. |
| **e2b** | `E2B_API_KEY` | 0 | **missing** (dropped) | **stub** | `sandbox/index.ts` is `export {}` + TODO; executor `catalog_crawl`/`ads_search` return `status:"skipped"` (`executor.ts:87-91`). Zero code reads. | Remove `sandbox/index.ts`, drop from `env.ts:55` + `/health` (`index.ts:142`). |
| **firecrawl** | `FIRECRAWL_API_KEY` | several | **set** | **wired** | Renders pages for the google-ads scrape and brand fetch tiers. No silent-fallback finding. | None. |
| **context.dev** | `CONTEXT_DEV_API_KEY` | several | **set** | **wired** (but is the inferior catalog target — see shopify) | Built-in scraper + 12-product catalog cap (`context.ts:44-46`). | None for wiring; fix the shopify mis-route that lands here. |

---

## 5. Toolkit ↔ API Sync Drift

| # | Finding | Severity | Evidence |
|---|---------|----------|----------|
| 1 | **9 catalog verbs have a `cliCommand` the CLI never registers** — MCP-callable (`mcp.ts:80`) but shell "unknown command". | high | `verbs.ts:130,158,328,726,817,828,875,944,1005`. Also `book ls/show/open/query/expand` documented (`book.ts:504-632`) but absent from catalog + MCP. |
| 2 | **Manifest/overview describe a Clearbit/favicon/render logo cascade that does not exist** — `logo.ts:462-484` probes only homepage/Wikipedia/logo.dev/simpleicons; brandfetch excluded (`356-360`) yet `verbs.ts:179-181` still lists `brandfetch.com`. | high | `logo.ts:462-484,356-360`; `verbs.ts:179-181`; fix `manifest.org:38`, `overview.org:35-36`, `brand.org:33-34`. |
| 3 | **Ads search silently returns 0 ads when `EXA_API_KEY` absent** (Exa→Valyu not done). | high | `scrape/exa.ts:38-40`; `ads/routes.ts:90`; `verbs.ts:197-222`; `ads.ts:147`. |
| 4 | **Manifest skill index lists 1 of 9 skills; `ENV_KEYS` omits `LOGO_DEV_TOKEN` + `GROQ_API_KEY`.** | medium | `manifest.org:52-56,8` vs 9 skill files; `logo.ts:368,519`. |
| 5 | **`/health` probe stale + orphan prod keys** (config drift both ways). `brandwork-*` binaries are pre-rename artifacts (bin correctly `brandnana`). | medium | `apps/api/src/index.ts:128-143`; `apps/cli/package.json:6-8`. |

Note: the manifest claim (#2) about logo ordering is the doc-layer counterpart to the §4 `logo-cascade` code verdict ("wired"). The code cascade is functionally honest; the *manifest/skill docs* describing it are wrong (list brandfetch, wrong tier order). Both should be reconciled to the actual `logo-fetch.ts` cascade.

---

## 6. Book Pipeline + Workbook-CLI Status

**Verdict: a 42-page book cannot be produced today.** Severity-ranked findings:

| # | Finding | Severity | Evidence |
|---|---------|----------|----------|
| 1 | **No 42-page composition — deck of at most 11 slides.** `presentation-shell.ts:5` says 10-slide brand book; 11-entry BUILDERS map gated by `curate.ts` `ALL_SLIDES` (11 keys), fallback 10. `document-shell.ts renderDocument` is used only by `agent/executor.ts`, never by the book pipeline. | high | `presentation-shell.ts:5,587-591,596`; `curate.ts:20-32,83-94`; `pipeline.ts:32` |
| 2 | **`wb` CLI runtime never invoked — static template.** `book-bundle.ts:1-9` says workbook-cli cannot run in a Worker and hand-ports minimal bundling; no WASM; never shells `wb build/unbundle/preview/serve`. | high | `book-bundle.ts:1-9,30-33`; `presentation-shell.ts:373` |
| 3 | **Bundle omits `data-version` — `wb unbundle` rejects every book.** Forge `unbundle.mjs:38-43` hard-fails unless `data-version == 1`; brandnana emits the tag without it. `extract-metadata.ts:66-80` ignores it, masking the break. | high | `presentation-shell.ts:209`; `book-bundle.ts:57`; forge `embedSource.mjs:41-42,117`, `unbundle.mjs:38-43` |
| 4 | **Catalog leg is a hardcoded 0-product stub** that still charges `0.001` and emits a green `catalog.crawl status:ok` event. `vendorToSeedShape` hardcodes empty products. SKILL.md still advertises product counts/OQL queries. | high / blocker | `pipeline.ts:334,336-364,930`; `skill-md.ts:106,120,132,154` |
| 5 | **Ads Exa branch is dead code** — EXA absent, not repointed to Valyu; empty catch swallows the throw; ads fall solely to scrapecreators/meta. | high | `pipeline.ts:19,235-258,256`; `exa.ts:37-38`; `verbs.ts:1589` |
| 6 | **Metadata/filename/provenance drift + masked failures.** `extract-metadata.ts:181-238` reads org props (`SLUG`/`NAME`/`AD_COUNT`/…) that `templates.ts:14-23,128` never emit (so counts zero out); `verbs.ts:1559` says `slug.workbook.html` but pipeline writes `slug.html`; pipeline swallows all leg failures (`190-207,256,287-289,440-451,660-671`) so zero-signal domains return 200 with a default 3-color palette (`909-914`); only a throw yields 502 (`routes.ts:120-123`). | medium | as cited |
| 7 | **Orphan prod keys absent from the book module** (no GROQ/THE_COMPANIES/WORKOS/VALYU consumers; auth uses `requireBearer` not WorkOS; references dead EXA). | info | `pipeline.ts:20,560-562,620-624,634-641`; `routes.ts:24`; `serve.ts:58` |

Beads note: `ad-3ul.14` was wrongly closed — the catalog stub + EXA gate make every book ship "Catalog 0".

---

## 7. Substrate / Agent / Runtime-Consumer Status

**Verdict: the brandnana-strategist agent is NON-FUNCTIONAL in the cloud runtime.** All three core capabilities fail at the deploy/contract level.

| # | Finding | Severity | Evidence |
|---|---------|----------|----------|
| 1 | **Cannot query existing brand books or workspace data.** `wb workbooks query` → `Client::connect()` needs `~/Workbooks/Engine/listen.json` OR `WB_DAEMON_URL+WB_DAEMON_TOKEN`. The cloud engine never writes `listen.json` (only the desktop Tauri sidecar does); the service never sets the env pair. Every daemon-backed `wb` command fails at connect. Also kills `wb agent spawn`, `wb memory save`, `wb insert`, `wb describe`. | blocker | `cli/wb/src/cmd/workbooks_query.rs:14,25`; `cli/wb/src/daemon.rs:23-64`; `desktop/src-tauri/src/sidecar.rs`; `services/brandnana-agent/entrypoint.sh` (no `WB_DAEMON_*`) |
| 2 | **Neither `brandnana` nor `wb` (nor `node`/`jq`) is installed in the image.** Dockerfile runtime stage `apk add`s only ca-certs/curl/etc. and COPYs the Elixir release + profile. PATH gets `~/Workbooks/Workbox/bin` prepended (`session_runner.ex:308-311`) — a dir the image never creates. `wb build` also needs `node` for the forge toolchain. | blocker | `services/brandnana-agent/Dockerfile:67-103`; `runtime/.../session_runner.ex:308-311,317`; `cli/wb/src/cmd/workbook.rs` |
| 3 | **`BRANDNANA_API_KEY` + `OPENROUTER_API_KEY` are scrubbed before agent bash.** `ToolRegistry.build_env/1` scrubs any name containing `API_KEY/SECRET/TOKEN` unless in `WB_FORWARD_SECRETS` — which the service NEVER sets. The manifest claims the key reaches the agent "via the `WB_FORWARD_SECRETS` allowlist". Net: every `brandnana` call / direct OpenRouter curl 401s. | blocker | `runtime/.../tool_registry.ex:166,194-218`; `session_runner.ex:315-322`; `toolkits/brandnana/manifest.org:29-30`; `services/brandnana-agent/entrypoint.sh:49,59` |
| 4 | **Shipped profile is STALE and diverges from canonical; no sync script.** Dockerfile ships `services/brandnana-agent/profile` (2026-05-29); canonical edited copy is `substrates/brandnana/profile` (2026-06-03). Shipped `:TOOLKITS:` is `bash wb` (omits `brandnana`) and tells the agent to use raw `curl`+`jq`; canonical declares `bash wb brandnana` + `MAX_TURNS`. Fixes land in a copy that never deploys. | high | `Dockerfile:83`; git log on both `brandnana-strategist.org`; no sync script found |
| 5 | **Shipped brand-research skill curls endpoints not in the contract** — `/v1/scrape/homepage`, `/v1/logo`, `/v1/screenshot`, `/v1/verify-brand`, `/v1/multipage` and fields like `.brand_css_vars`, `.colors_ranked`. None exist in `verbs.ts` (real surface is `brand fetch <domain> ?include=…` returning `{brand,extras}`). | high | `services/.../skills/brand-research.org:45-78`; `verbs.ts:100-112` |
| 6 | **`wb memory remember` called with two positional args; CLI accepts one.** Skills do `wb memory remember "research:$DOMAIN" "$JSON"` but `MemoryCmd::Remember` has a single `body` positional → clap rejects. `recall`/`search` are substring scans, not keyed gets. Cross-session brand prior is broken at the CLI contract. | high | `cli/wb/src/cli.rs:979-1005`; `cli/wb/src/cmd/memory.rs:169-291`; substrates+services skills |
| 7 | **`wb memory` writer path and engine reader path diverge.** `wb` writes `~/Workbooks/Engine/memory/<tier>/<tier>.org`; engine reads `$WB_DATA_ROOT/Engine/memory/<tier>.org` (flat). Different dir AND layout; in-container `WB_DATA_ROOT=/var/wb` but `HOME=/home/brandnana`. Memory never round-trips. | high | `cli/wb/src/cmd/memory.rs:52-58,179-182`; `cli/wb/src/cmd/query.rs:25-31`; `runtime/.../memory.ex:77-80`; `data_root.ex:8-17` |
| 8 | **Skills cat a `/opt/...` skill tree the image never creates.** Canonical skills `cat /opt/brandnana-profile/Engine/skills/brandnana/...` but the prompt says skills live at `/opt/profile/skills/`, and the image ships only 5 flat skills (no `brandnana/` or `wb/` subtrees). Discovery escape hatch is dead. | medium | substrates skills vs `Dockerfile:83` |
| 9 | **publish-workbook + make-image depend on `/v1/book/publish` + `/v1/asset/upload`** (TODO `wb-o2ax`); no such verbs in `verbs.ts`; either un-cataloged routes or 404s. make-image's direct-OpenRouter note admits "the brandnana cost ledger does NOT see these calls" — final deliverable + cost accounting are off-contract. | medium | substrates publish-workbook/make-image skills; `verbs.ts` grep = no match |
| 10 | **Intra-pipeline filename drift.** Canonical research writes `raw/$DOMAIN/brand.json` but downstream skills read `scrape.json`/`verify.json`/`multipage.json`/`screenshot.json`/`logo.json` (never produced). | low | substrates brand-research vs strategize/compose/make-image/publish skills |
| 11 | **`fly.toml` uses legacy `WORG_*` env names** while entrypoint/Dockerfile standardized on `WB_*`; health-check path mismatch (`/api/about` vs `/api/health`); README tells operators to set `WORG_PUBLIC_BEARER`. Fallbacks cover it today — silent-break risk later. | low | `services/.../fly.toml:20-27,42-48`; `Dockerfile:99-106`; `entrypoint.sh:23,46-47`; `README.org:46-49` |

---

## 8. Tests & Live-Smoke Results

| Suite | Command | Result | Detail |
|-------|---------|--------|--------|
| Typechecks | `tsc --noEmit` | **FAIL** (exit 2) | api 11 errors, cli 8 errors — `resolve.ts` and `migrations.ts`. |
| Unit tests | `bun test` | **PASS** | api 172 pass (7 files), cli 76 pass (5 files) — heavily mocked. |
| AI smoke + evals | runner + curl | **FAIL** | `/v1/_smoke/ai` returns **502**; OpenRouter **401** (`ai.ts:101` vs prod OpenRouter). `/health` secrets (`index.ts:128-143`) stale. |
| Nightly smoke (`smoke.yml`) | `test/smoke.ts` | **RED by design** | Hard-requires the absent `EXA_API_KEY` + `CF_AI_GATEWAY_TOKEN` (`test/smoke.ts:66-72`). |

**Live smoke calls (against `https://api.brandnana.net`):**
- `GET /social/instagram/nike` → **200** with real normalized summary (nike, 291,995,462 followers). Confirms scrapecreators wired + key set in prod.
- `GET /social/instagram/cocacola` → **502 upstream_unavailable** (transient). Confirms graceful degradation; the 502 (vs 503) re-confirms the key is set.
- `POST /ads/search {query:"running shoes", source:"all"}` → **200 {count:0, ads:[]}**. Confirms the Exa discovery leg is silently dead in prod (no brand → no meta leg either).

> The unit suite passing does NOT validate vendor wiring — it is mocked. The two real signals are (a) the live social calls (a genuine win) and (b) the live empty `ads/search` (a confirmed silent-fallback trap).

---

## 9. Config / Secrets Drift + Corrected `/health` List

**Headline drift classes:** (1) code expects a provider whose key is absent (Exa, CF AI Gateway, GOOGLE_API_KEY phantom, E2B); (2) key is set with no consumer (GROQ/THE_COMPANIES/WORKOS×2/VALYU). The worker's own self-report (`/health`) is wrong in BOTH directions.

| # | Finding | Severity | Evidence |
|---|---------|----------|----------|
| 1 | **Phantom `GOOGLE_API_KEY`** declared+documented (`env.ts:51-54`) but vision routes Gemini via OpenRouter; zero `env.GOOGLE_API_KEY` readers. | high | `env.ts:51-54`; `vision-verify.ts:19-20,64,108` |
| 2 | **Nightly smoke hard-requires absent `EXA_API_KEY` + `CF_AI_GATEWAY_TOKEN`** → `smoke.yml` red-by-design. | high | `test/smoke.ts:66-72`; `smoke.yml:4-7` |
| 3 | **`/health` BLIND to prod-critical `CEREBRAS_API_KEY` + `CLERK_SECRET_KEY`**; cannot surface GROQ/THE_COMPANIES/WORKOS/VALYU. | high | `index.ts:128-143`; `dispatcher.ts:183,237`; `portal-keys.ts:157`; `cli-flow.ts:157` |
| 4 | **`/health` probes intentionally-absent `EXA_API_KEY` (`:137`) + `E2B_API_KEY` (`:142`)** which read missing forever; EXA still has dead-in-prod paths. | medium | `index.ts:137,142`; `scrape/exa.ts:37` |
| 5 | **Five ORPHAN prod secrets, zero worker consumers, absent from `env.ts`:** GROQ / THE_COMPANIES / WORKOS_API_KEY / WORKOS_CLIENT_ID / VALYU (GROQ only in local CLI). | medium | grep env reads = 0 each; `apps/cli/src/commands/logo.ts:516,541` |
| 6 | **`E2B_API_KEY` dead** across `env.ts:55`, `index.ts:142`, `dev.vars.example:33`, `wrangler.toml:55`; stale `LOGODEV`/`BRANDFETCH` (`wrangler.toml:53-54`); `dev.vars.example` omits live keys; `secrets-push.sh:45-46` skips empties so a clean push yields a non-functional worker. | low | as cited |

### Corrected `/health` `secretKeys` list

**Remove** (intentionally absent / dead-feature): `EXA_API_KEY`, `E2B_API_KEY`, `CF_AI_GATEWAY_TOKEN`, `GITHUB_CLIENT_ID`, `GOOGLE_API_KEY`.

**Add** (prod-critical, currently blind): `CEREBRAS_API_KEY`, `CLERK_SECRET_KEY`.

**Add as migration-pending** (orphan today, will report present): `GROQ_API_KEY`, `VALYU_API_KEY`, `WORKOS_API_KEY`, `WORKOS_CLIENT_ID`, `THE_COMPANIES_API_KEY`.

**Final corrected list:**
`CEREBRAS_API_KEY, OPENROUTER_API_KEY, CLERK_SECRET_KEY, FIRECRAWL_API_KEY, SCRAPECREATORS_API_KEY, CONTEXT_DEV_API_KEY, VALYU_API_KEY, WORKOS_API_KEY, WORKOS_CLIENT_ID, GROQ_API_KEY, THE_COMPANIES_API_KEY`
(`META_*` / `TIKTOK_*` / `GOOGLE_CLIENT_*` remain deferred and intentionally out of the list.)

### env.ts corrections
- **Delete:** `GOOGLE_API_KEY` (`:54`), `E2B_API_KEY` (`:55`).
- **Add** (migration, consumer-pending): `VALYU_API_KEY`, `WORKOS_API_KEY`, `WORKOS_CLIENT_ID`, `GROQ_API_KEY`, `THE_COMPANIES_API_KEY`.
- **Keep** `EXA_API_KEY` with a `DEPRECATED — repoint to Valyu` comment until the migration lands.

---

## Appendix — Two Headline Drift Classes (summary)

1. **Code expects an absent provider:** Exa (`scrape/exa.ts` throws; swallowed in `ads.search`), CF AI Gateway (dead module + misleading docstrings), `GOOGLE_API_KEY` (phantom, vision actually on OpenRouter), E2B (stub), and the agent service's `BRANDNANA_API_KEY`/`OPENROUTER_API_KEY` (present as secrets but scrubbed before agent bash).
2. **Key set with no consumer (orphan):** `GROQ_API_KEY` (worker), `THE_COMPANIES_API_KEY`, `WORKOS_API_KEY`, `WORKOS_CLIENT_ID`, `VALYU_API_KEY` — none declared in `env.ts`, none read in `apps/api/src`.

The single most dangerous "looks wired but isn't" trap is the `ads.search` Exa leg: a present-looking, catalog-advertised primary discovery surface that returns `200 {count:0}` in prod with zero signal — confirmed live.
