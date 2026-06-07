# BRAND-DATA-HARVEST — Stage 1 Design

**Status:** Design phase (no code changed). **Date:** 2026-06-03.
**Goal (user's words):** "return ALL data points no matter the brand or the website" — get around any bot block with the tools we have, "really elaborate everything" so the book is built from FULL brand context.

This is the design for **Stage 1** of the brandnana brand-book build: an **engine-resident agentic harvester** ("Brand Scout") that holds the scrape tools, adaptively pulls every retrievable data point across every section, verifies each one, escalates tools on resistance, **fails loud instead of silent-empty**, and writes a structured org + R2 substrate that the Stage-2 editor agent authors the book from.

Live proof target: **tecovas.com** against `https://api.brandnana.net` (auth via `~/.brandnana/key`; all 11 vendor secrets `set`; `BROWSER` binding `ok`). Every code claim below is cited `file:line`; every "live" claim was executed against the deployed worker.

---

## 0. Why a harvester (the bottleneck is composition, not capability)

The platform already ships ~155 verbs across 13 namespaces (`packages/schema/src/verbs.ts:24-1661`), 98 of them social across 18+ platforms, plus a real agentic layer in `apps/api/src/agent/*` (homepage-scrape, multipage-text, verify-brand, vision-verify, asset-probe, logo-fetch, screenshot-fetch, curate) orchestrated by `dispatcher.ts` → `planner.ts` → `executor.ts`.

But **the book pipeline ignores most of it.** `buildBook` (`apps/api/src/book/pipeline.ts:480-805`) calls only: a slug resolve, brand fetch+fonts, Meta ad-library (headline only), a **0-product catalog STUB** (`pipeline.ts:320-333`), optional competitor fetch, and the agentic logo/screenshot/scrape/curate/vision chain. It does **not** call `brand.company` (firmographics — grep of `pipeline.ts` for `fetchCompany`/`thecompanies` returns **nothing**), **any** `social.*` verb, `creative.analyze` (ad vision), the **real** catalog crawler, or any to-add source.

So "full brand context" is bottlenecked at composition. The fix is to insert a **research-only agent Plan** ahead of composition that fans out every verb adaptively, then hands the full harvested substrate to `composeBookData`.

---

## 1. FULL DATA MANIFEST — everything the book should pull

Legend: **HAVE** = live today. **THIN** = returns but underpopulated. **WIRE** = verb works but not called by book. **ADD** = no verb yet.

### IDENTITY
| Data point | Source / verb | Status | Evidence |
|---|---|---|---|
| Logo (ranked, tagged, media) | `logo.find` + agentic `fetchLogo`/`probeLogo` (homepage scrape, logo.dev, Wikipedia Commons, simpleicons; SVG-preferred; rejects favicons by aspect ratio; tags transparent/wordmark/mono) | **HAVE** | `verbs.ts:187-206`; `apps/cli/src/commands/logo.ts:29-57`; `pipeline.ts:543-601,687-690` |
| Color palette / swatches | `brand.fetch` (palette_json) + `design.tokens`; homepage CSS vars + theme-color + occurrence-ranked colors | **THIN** (3 swatches, accent=null) | live `/design/tokens` = `["#040404","#b1624c","#f9f1e9"]`; `pipeline.ts:815-848`; `verbs.ts:379-392` |
| Fonts / typography | `brand.fonts` + `design.tokens` (@font-face / Google / Typekit; dominance + fallback stacks + per-element usage) | **HAVE** (rich) | live = mundial 0.88 / lorimer-no-2 0.11 / borax-variable 0.01; `apps/cli/src/commands/brand.ts:149-195` |
| Styleguide (mode/typography/components) | `brand.styleguide` (context.dev) | **HAVE** | `verbs.ts:130-141` |
| Homepage screenshot (media) | `brand.screenshot` + agentic `homepageScreenshot` (1280×800) | **HAVE** | `verbs.ts:158-168`; `pipeline.ts:547,610-655` |
| Single product page (media+copy) | `brand.product` → name/price/images/features | **HAVE** | `verbs.ts:143-156`; `brand.ts:112-133` |
| Firmographics / company facts | `brand.company` (The Companies API): name, desc, tagline, industry, NAICS/SIC, employees, founded, revenue band, 6 social URLs, square logo | **WIRE** (+sparse) | live `/company` = name/desc/tagline + 6 socials, but industry/NAICS/SIC/employees/founded/revenue = **null**; `apps/api/src/scrape/thecompanies.ts:30-61`; **absent** from `pipeline.ts:480-805` |
| Design tokens: radii / spacing / gradients / shadows | planned `design extract-css` (Browser-Rendering computed-style) | **ADD** | `design.tokens` returns these as `null`; `apps/cli/src/commands/design.ts:10-20` |

### VOICE
| Data point | Source | Status | Evidence |
|---|---|---|---|
| Tone / voice / style signal | **synthesized** by agentic layer: `harvestMultiPage` (About/Press/Journal/PDP) → `curate()` (Cerebras glm-4.7) → `verifyStyleViaVision`; `design.tokens.voice` (name/slogan/desc); ad copy from `creative.analyze` | **HAVE** but shallow | `apps/api/src/agent/multipage-text.ts:17-43`; `pipeline.ts:602-655`; live `voice.slogan = "Forever West."` |
| Site copy corpus (mission/values/FAQ/shipping/returns/product desc) | `harvestMultiPage` page kinds | **THIN** (MAX_PAGES=3, 4KB/page) | `multipage-text.ts:13-24` |
| Audience reception / sentiment | comments + reviews + Reddit are pullable; **no sentiment scorer** | **ADD** | `verbs.ts:470-479,1019-1028` |

### SOCIAL (98 verbs / 18+ platforms — all live via `SCRAPECREATORS_API_KEY`)
| Data point | Source | Status | Evidence |
|---|---|---|---|
| Profiles + followers (IG, TikTok, YT, X, FB, LinkedIn person+company, Threads, Pinterest, Bluesky, Twitch, Snapchat, Truth) | per-platform profile verbs | **WIRE** (book calls none) | `verbs.ts:414-1562`; live TikTok @tecovas = **203,700 followers**, verified |
| Posts / reels / videos / shorts / tweets / VODs | per-platform content verbs | **WIRE** | `verbs.ts:414-1562` |
| Comments / transcripts | IG/TikTok/YT/FB/Reddit comments; IG/TikTok/YT/X/Rumble transcripts | **WIRE** | `verbs.ts` comment/transcript verbs |
| Search / trending (cross-platform) | TikTok/YT/IG/Reddit/Threads/Pinterest/Google search + trending | **WIRE** | `verbs.ts:594-636,820-840,994-1003` |
| Bio-link aggregators (linktree/komi/pillar/linkbio/linkme) | link-aggregator verbs; `brief.get` fans out 6 channels | **HAVE** (handle discovery) | `verbs.ts:356-375` |
| UGC / creator mentions aggregation | search verbs exist; **no aggregator** | **ADD** | `verbs.ts:594-636,994-1003,820-840` |

### ADS
| Data point | Source | Status | Evidence |
|---|---|---|---|
| Ad libraries (Meta + Google Transparency + LinkedIn) | `ads.search`, `ads.google`, `social.google.advertiserAds`, `social.linkedin.ads`, `ads.meta.*` | **HAVE** (book uses Meta only, headline only) | `verbs.ts:210-309,696-705,1506-1526`; `pipeline.ts:236-264`; live Google = **5 creatives**, LinkedIn = clean true-negative |
| Creative analysis (what the ad SHOWS) | `creative.analyze` → hook, products_visible, people_count, setting, text_overlays, cta, mood, palette, pacing, key_moments (maverick image / Gemini video) | **WIRE** (book never runs it) | `apps/cli/src/commands/creative-vision.ts:14-37,98-197` |

### CATALOG
| Data point | Source | Status | Evidence |
|---|---|---|---|
| Products / variants / prices / images / collections | `catalog.crawl` strategies: auto, shopify, context-dev, sitemap, llm — streams NDJSON into SQLite (+optional R2 mirror) | **HAVE via CLI, BROKEN in book** | `verbs.ts:313-352`; `apps/cli/src/commands/catalog.ts:115-188` |
| Book catalog section | `runCatalog` is a **hardcoded 0-product STUB** that never calls the crawler | **broken** | `pipeline.ts:320-333` (comment: "context.dev products endpoint is /v1/products which is not currently wrapped") |
| Reviews / ratings (on-site + off) | only `social.tiktokShop.productReviews` today; no Yotpo/Okendo/Judge.me/Trustpilot/JSON-LD AggregateRating | **ADD** | `verbs.ts:1066-1075` |

### CONTEXT (to-add, high value for "full context")
| Data point | Source | Status | Evidence |
|---|---|---|---|
| Press / news / PR coverage | `search.news` (Valyu) — keyed on brand + domain | **ADD** | `VALYU_API_KEY` set; only used for domain resolve today, `verbs.ts:397-410` |
| Founders / executives / leadership | The Companies API people fields (only ~14 of ~80 projected) + Valyu "founder of X" + LinkedIn company-page | **ADD** | `thecompanies.ts:30-61`; `verbs.ts:707-727` |
| Funding / financials / ownership | Valyu / Crunchbase-style search; The Companies API finances when present | **ADD** | live revenue = null; `thecompanies.ts:55-56` |
| Sitemap / site taxonomy | `sitemap.map` returning collections, categories, content hubs, store-locator | **ADD** (sitemap strategy is product-only today) | `verbs.ts:313-340`; `apps/api/src/catalog/sitemap.ts` |
| Competitor set (auto-discovery) | `fetchCompetitorData` exists but competitors must be **passed in**; no auto-discovery | **ADD** | `pipeline.ts:373-436`; `verbs.ts:1577-1581` |

---

## 2. ROBUST AGENTIC HARVESTER ARCHITECTURE — "Brand Scout"

### Seat
The harvester is a **research-only agent Plan** that reuses the existing intent → plan → execute seam: `apps/api/src/agent/dispatcher.ts:28` (intent classify), `planner.ts`, `executor.ts:1-21`. It runs as an agent in the Elixir engine holding the scrape **toolset** (below). Each plan step = one data point; the agent fans steps out in parallel, validates each result, and escalates tools on resistance before declaring a point done-or-failed.

### Tool set (the verbs the agent holds)
1. **resolve** — `resolve.query` (Valyu web_search leg) → canonical domain (`verbs.ts:397-409`).
2. **identity** — `brand.fetch`, `brand.fonts`, `brand.styleguide`, `design.tokens`, `logo.find`, `brand.screenshot`, `brand.product`.
3. **company** — `brand.company` (The Companies API) + Valyu backfill for null firmographics.
4. **copy** — `harvestMultiPage` (widened) + `curate()` for voice synthesis.
5. **catalog** — `catalog.crawl` with a **real auto-cascade** shopify → sitemap(JSON-LD) → llm(Firecrawl).
6. **social** — per discovered handle: profile + recent posts + top reels/videos + transcripts + comments, across the 18 platforms.
7. **ads** — `ads.search` (Meta + Google + LinkedIn legs) + `creative.analyze` over each returned creative.
8. **context** — `search.news` (press), leadership/funding (Valyu + The Companies API), reviews (JSON-LD + Trustpilot), UGC search, sentiment pass (OpenRouter).
9. **media/R2** — `captureScreenshot` cascade + `/mirror/images` to R2 for every binary.
10. **verify** — `verify-brand` (wrong-brand detection, `pipeline.ts:569-581`) + `vision-verify`.

### Per-source escalation policy (the "get around any block" mechanism)
Every fetch flows through **one shared escalation chain** (today it is forked across harvesters and catalog adapters — see Fix List). The chain, in order, with verification at each rung:

1. **direct + realistic UA** — Chrome UA (already in `homepage-scrape.ts:204-209`), verify body is non-stub and on-brand.
2. **host-variant retry** — try apex ↔ `www` ↔ `*.myshopify.com` backend (grepped from homepage). *This alone recovers tecovas's full catalog — apex is Shopify-reachable, www is not.*
3. **context.dev scrape** — `GET /v1/scrape/html?url=` (auto proxy escalation), `fetch-brand.ts:171-179`.
4. **CF Browser Rendering** — the real bypass tier: realistic UA → headless Chromium → post-render HTML / `page.screenshot`. (Currently **broken** two ways — see Fix List.)
5. **Firecrawl render** — JS-rendered markdown + screenshot for the hardest sites (`firecrawl.ts:15`, ~$0.002/page).
6. **ScrapeCreators / sitemap / JSON-LD** — for social and headless-Shopify catalog where HTML fetch isn't the right tool at all.

Per-type fallbacks layer on top: **palette** → context.dev colors → homepage `<meta theme-color>` + CSS vars → **vision-on-screenshot** (maverick); **catalog** → shopify → sitemap JSON-LD → Firecrawl-rendered collection; **screenshot** → context.dev hosted PNG → CF puppeteer → Firecrawl → mshots, all mirrored to R2.

### "Done" decision per data point
A point is **DONE** when (a) the result passes its per-type **verify predicate** (palette has ≥N swatches with roles; catalog has >12 products with prices; company has non-null firmographics; screenshot byte-validates as an image; social profile has a follower count) AND (b) `verify-brand` confirms it's the right brand. Otherwise the agent **escalates to the next rung** and retries. If the chain is exhausted, the point is recorded as a **loud explicit failure** (`{status:"failed", attempts:[…], last_error}`) — **never a silent empty**. True-negatives (e.g. "no LinkedIn ad presence" for tecovas) are recorded as **real data points**, not retried.

### Output substrate
The agent writes a structured **org file** (one section per manifest row, with provenance + the winning tool per point) plus an **R2 media substrate** (every logo/screenshot/product image/ad creative/og:image mirrored via `/mirror/images` → `/assets/<sha>`, dedup by sha256, `apps/api/src/mirror/routes.ts:86-135`). Stage 2's editor agent authors from this — it never re-scrapes.

---

## 3. CONCRETE FIX LIST (code changes to make harvesting robust)

Prioritized. Each is a real, verified defect with `file:line`.

**P0 — Unblock the two known gaps + the bypass tier**

1. **Wire the real catalog into the book.** `pipeline.ts:320-333` is a hardcoded 0-product stub that never calls the crawler. Replace `runCatalog` to invoke the real cascade coordinator. → `apps/api/src/book/pipeline.ts:320-333`.
2. **Make `auto` cascade past context-dev.** `catalog/routes.ts:53-58` does `shopify → context-dev` only ("sitemap never picked by auto"). For headless-Shopify (sitemap_products.xml exists AND /products.json 404s) route to **sitemap**; add llm/Firecrawl as final rung. → `apps/api/src/catalog/routes.ts:53-58` + `apps/api/src/catalog/shopify.ts:136-149`.
3. **Fix `isShopify` host blindness.** Tri-state (yes/no/unknown), retry apex ↔ www ↔ grepped `*.myshopify.com`; loud stats error when products ≤12. The 404 is swallowed to `false` at `shopify.ts:118,136-149`, demoting a 1358-product catalog to the 12-cap context-dev path.
4. **Fix the browser-render dep.** `fetch-brand.ts:137` imports `@cloudflare/puppeteer` which is **not in any package.json and not in node_modules** (verified) — the import throws and is swallowed at `fetch-brand.ts:165-168`, so the bypass tier never fires. Add the dep **or** switch to the CF Browser Rendering REST endpoint. → `apps/api/src/scrape/fetch-brand.ts:115-169`.
5. **Fix the fictional browser host.** `homepage-scrape.ts:186` and `multipage-text.ts:192` POST to `https://browser-rendering.cf/v1/content` — DNS does not resolve, so every bot-block fallback silently fails. Point both at the real CF binding / REST endpoint (implement once in a shared `scrape/browser.ts`). → `homepage-scrape.ts:185-198`, `multipage-text.ts:191-204`.

**P1 — Elaborate the thin points**

6. **Palette: always union + vision fallback.** The merge that fans palette to 8 only fires when the vendor returns **0** (`pipeline.ts:820-847`) — make it **always union** context.dev + CSS vars + theme-color + dominant colors. Add HSL to `normalizeHex` (skips Tailwind HSL vars today) and seed `rankColors` with the parsed `theme_color` (read at `homepage-scrape.ts:245` but never fed to ranking). Add the **vision-on-screenshot** fallback (maverick `image_url`, already in `creative-vision.ts`) when still thin. → `homepage-scrape.ts:245,309-323,325-360`; `pipeline.ts:815-848`; `apps/api/src/design/routes.ts:97`.
7. **Wire `brand.company` into the book + Valyu backfill.** `fetchCompany` is never called by `buildBook`. Add it; backfill null founded/HQ/employees/revenue via Valyu search. → `pipeline.ts:480-805`; `thecompanies.ts:30-61`.
8. **Screenshot: capture + mirror, add classes.** `screenshot-fetch.ts:20-29` returns only a hot-linked mshots URL (no R2), and mshots returns 403 with a Chrome UA. Make context.dev's **working** `getScreenshot` (`context.ts:199-206`, exposed `brand/routes.ts:294-304`, live = real 1920×1080 PNG) the **primary** capture; route every binary through `/mirror/images` → R2 (`mirror/routes.ts:86-135`); add full-page / mobile / PDP / og:image classes. mshots demotes to tertiary. → `screenshot-fetch.ts`, `pipeline.ts:952`, `presentation-shell.ts:573-581`.
9. **Set a good default UA across all fetchers.** Crawler UAs invite WAF blocks: `asset-probe.ts:185` (`brandnana-asset-probe/1.0`), `logo-fetch.ts:51` (`brandnana-bot/1.0`), `sitemap.ts:18` (`brandnana-crawler/0.1`), `shopify.ts:12`. Centralize realistic headers. → those four lines.
10. **Sitemap filter hygiene.** Exclude `/products/gift-cards`, dedupe `?color=` variants, and fall back to a rendered fetch when raw JSON-LD has no `@type:Product`. → `apps/api/src/catalog/sitemap.ts:123-142,305-311`.

**P2 — Wire the rest into the book + add context sources**

11. **Run `creative.analyze` over returned ads** + add Google/LinkedIn legs (book stores headline+id only at `pipeline.ts:236-264`).
12. **Feed social into the book** (book ingests zero `social.*` today): per discovered handle, profile + posts + top videos + comments.
13. **Widen multipage harvest** (`multipage-text.ts:13-24`): MAX_PAGES 3 → 8, add FAQ/shipping/returns/values/sustainability/full-PDP patterns; store the full copy corpus.
14. **Add the to-add sources:** `search.news` (press, Valyu), leadership/funding projection + Valyu, reviews (JSON-LD AggregateRating + Trustpilot), UGC cross-platform search, sentiment pass (OpenRouter), `sitemap.map` taxonomy, competitor auto-discovery (Valyu "brands like X" / same NAICS).
15. **Coordinator dedup on retry.** When the agent escalates strategies on one domain, reuse one `crawl_id` or `finishCrawl` the prior slot first, so `/status` reflects the live attempt not a stale `running` slot. → `apps/api/src/catalog/routes.ts:96-116,192-199`; `coordinator.ts`.

---

## 4. TECOVAS PROOF — every Stage-1 point is gettable

Per-data-point, with the **winning tool** (all live against `api.brandnana.net`):

| Data point | Result (live) | Winning tool |
|---|---|---|
| Logo | image (svg/png) + rejected candidates | logo cascade (`logo.find`) |
| Palette | `["#040404","#b1624c","#f9f1e9"]` (3); fallbacks add `#A75742`/`#FCF9F4` (theme-color) and `[#964B00,#FFFFFF,#000000,#F5F5DC,#754975,#C9C4B5]` (vision/maverick on screenshot) | `/design/tokens`, then **theme-color scrape**, then **vision** |
| Fonts | mundial 0.88 / lorimer-no-2 0.11 / borax-variable 0.01 + fallback stacks | `/design/tokens` |
| Voice / slogan | `"Forever West."` + curated style signal | `design.tokens.voice` + `curate()` |
| Screenshot | `status:ok`, viewport (also a real 1920×1080 PNG, 1,038,917 bytes, valid PNG) | `GET /brand/:domain/screenshot` (context.dev) |
| Company | name/desc/tagline + 6 socials; firmographics null → Valyu backfill | `/brand/:domain/company` + Valyu |
| Catalog | apex `tecovas.com` is Shopify-reachable; **www is headless** (/products.json → 404 HTML, 327KB) → escalate to **sitemap** (482-URL `sitemap_products.xml`, JSON-LD per PDP: Cartwright $375 in 4 colorways) → **Firecrawl** for JS depth (53 product links, 59KB md) | host-variant retry → **sitemap** → **Firecrawl** |
| Social — TikTok | **203,700 followers**, 300 posts, verified, "Forever West" | `/social/tiktok/:handle` (ScrapeCreators) |
| Social — YouTube | 28,000 subs, 68 videos, 11.66M views, channel UCbsLubi… | `/social/youtube/:handle` |
| Ads — Google | **5 live creatives**, advertiser AR12637599148565069825 | `/ads/search` source=google |
| Ads — LinkedIn | 0 results, warning "no ad-library matches" — **true-negative, recorded as a data point** | `/ads/search` source=linkedin |

Net: **all Stage-1 points retrievable for tecovas.** The two task-brief gaps are now nuanced — palette is not zero (3 swatches, fixable to 8-12 via union+vision), and catalog "fails" only because the book wires a stub and `auto` stops at context-dev; the working escalation (host-variant → sitemap → Firecrawl) was proven live.

---

## 5. HOW THIS BECOMES STAGE 1 OF THE BRAND-BOOK BUILD

```
STAGE 1  Brand Scout (this doc)            STAGE 2  Editor agent
─────────────────────────────────         ──────────────────────────
resolve → identity → company →             reads the org + R2 substrate
copy → catalog → social → ads →    ───►    (never re-scrapes) and AUTHORS
context → media/R2, each verified           each book section from FULL
& escalated, fails LOUD                      context: composer/writer/
                                             strategist/concept-deck
writes:  brand-<domain>.org  +  R2 media
```

- The harvester runs **first**, as a research-only Plan on the dispatcher → planner → executor seam (`apps/api/src/agent/*`), producing the **substrate**: a provenance-stamped org file (one section per manifest row, winning tool recorded) + an R2 media library (sha-deduped).
- `composeBookData` / the Stage-2 editor agent (`strategist.ts`, `composer.ts`, `writer.ts`, `concept-deck.ts`) then **authors from the substrate only** — no scraping in Stage 2, so the book is deterministic and the editor sees full context, not 3 pages and a stub catalog.
- The harvester's **loud-failure contract** means a missing point is visible in the org (`status:failed` with attempt log), so the editor can either skip or trigger a targeted re-harvest, instead of silently shipping an empty catalog.

---

## 12-LINE SUMMARY

1. Capability exists (~155 verbs, full agentic layer); the bottleneck is the **book pipeline ignoring most live verbs** (`pipeline.ts:480-805`).
2. The book's catalog is a **hardcoded 0-product stub** (`pipeline.ts:320-333`) — never calls the real crawler.
3. `auto` catalog stops at `shopify → context-dev`; **sitemap/llm never auto-picked** (`catalog/routes.ts:53-58`).
4. tecovas catalog "fails" only because **www is headless** (/products.json 404) — apex is Shopify-reachable; **host-variant → sitemap → Firecrawl** recovers it (proven live).
5. Palette is **not zero**: 3 swatches live; fixable to 8-12 via **always-union + theme-color + vision-on-screenshot** (maverick).
6. `brand.company` firmographics verb is **never called by the book**; null fields need **Valyu backfill**.
7. The **bypass tier is broken twice**: `@cloudflare/puppeteer` is not installed (`fetch-brand.ts:137`) and fallbacks POST to the **fictional host** `browser-rendering.cf` (`homepage-scrape.ts:186`, `multipage-text.ts:192`).
8. Screenshots = **one hot-linked mshots URL, never in R2**; context.dev's working PNG endpoint is deployed but unused (`screenshot-fetch.ts`, `brand/routes.ts:294-304`).
9. Weak crawler **UAs invite WAF blocks** (`asset-probe.ts:185`, `logo-fetch.ts:51`, `sitemap.ts:18`).
10. Design: an engine-resident **Brand Scout** agent holds the scrape tools, escalates per source (direct+UA → context.dev → CF browser → Firecrawl → ScrapeCreators/sitemap/JSON-LD) with **verify+retry**, and **fails loud, never silent-empty**.
11. "Done" per point = passes a per-type verify predicate + `verify-brand`; true-negatives (no LinkedIn ads) are recorded as real data.
12. Stage 1 writes the **org + R2 substrate**; Stage 2's editor agent **authors from it without re-scraping** — full context, deterministic book.

## PRIORITIZED FIX LIST

**P0 (unblock + bypass):**
1. Wire real catalog into book — `pipeline.ts:320-333`.
2. `auto` cascade shopify→sitemap→llm — `catalog/routes.ts:53-58`, `shopify.ts:136-149`.
3. Tri-state `isShopify` + host-variant retry + loud ≤12 error — `shopify.ts:118,136-149`.
4. Add `@cloudflare/puppeteer` dep or CF REST — `fetch-brand.ts:115-169` (import throws today).
5. Replace fictional `browser-rendering.cf` host with real CF binding (shared `scrape/browser.ts`) — `homepage-scrape.ts:185-198`, `multipage-text.ts:191-204`.

**P1 (elaborate thin points):**
6. Palette always-union + HSL in `normalizeHex` + seed theme-color + vision fallback — `homepage-scrape.ts:245,309-360`, `pipeline.ts:815-848`, `design/routes.ts:97`.
7. Wire `brand.company` + Valyu backfill — `pipeline.ts:480-805`, `thecompanies.ts:30-61`.
8. Primary screenshot = context.dev `getScreenshot`, mirror all media to R2, add capture classes — `screenshot-fetch.ts`, `context.ts:199-206`, `mirror/routes.ts:86-135`.
9. Realistic default UA everywhere — `asset-probe.ts:185`, `logo-fetch.ts:51`, `sitemap.ts:18`, `shopify.ts:12`.
10. Sitemap filter: skip gift-cards, dedupe `?color=`, rendered fallback when no JSON-LD — `sitemap.ts:123-142,305-311`.

**P2 (wire rest + add context):**
11. `creative.analyze` over ads + Google/LinkedIn legs — `pipeline.ts:236-264`.
12. Feed `social.*` into book (zero today).
13. Widen multipage harvest 3→8 + more page kinds — `multipage-text.ts:13-24`.
14. Add press(Valyu)/leadership/funding/reviews/UGC/sentiment/`sitemap.map`/competitor auto-discovery.
15. Coordinator dedup on strategy-retry — `catalog/routes.ts:96-116,192-199`.
