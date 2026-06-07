# BRAND-BOOK-PLAN.md — Agent-Authored, Self-Validated, OQL-Queryable Brand Book (dynamically sized)

> LOCKED DECISIONS (2026-06-03): render = **presentation (slides)**; page count = **dynamic / data-driven, NO fixed limit** (the §3 outline is a SEED scaffold, not a fixed 42); **single-brand one-shot** first; **full board with graceful degradation** (missing data → `needs_data`, non-blocking; pivot focus instead of emitting a broken page). Build model = **generative authoring, not templating** (see §1b).

Status: DRAFT PLAN (workbooks-skill Plan deliverable). Read-only synthesis. No code written.
Author context: replaces the broken server-side book pipeline at `projects/brandnana/apps/api/src/book/*`.
Date: 2026-06-03.

---

## 1. Problem & Wow-Moment

### The promise vs. reality
"One-shot 42-page brand book" is a marketing PROMISE (P7) that was never built. The audit docs
flag it explicitly as unbuilt and even offer to drop the page-count claim:

- `PROMISES.md:28-29` (P7 promise), `:128-141` ("42-page brand book is currently a ≤11-slide static
  template that wb itself cannot round-trip"), `:216-217` (DoD offers to drop the 42-page claim).
- `AUDIT.md:127` ("a 42-page book cannot be produced today"), `AUDIT.md:131` (deck of at most 11 slides).

The current server pipeline has four fatal gaps, all confirmed:
1. **Catalog is a 0-product stub** that still emits a green `catalog.crawl status:ok` and charges
   $0.001 — it never calls the real crawler (`book/pipeline.ts:334-364`; real crawler lives in the CLI
   at `apps/cli/src/commands/catalog.ts:144-201`).
2. **At most 11 slide types, 10 in the deterministic fallback** — not 42 pages
   (`book/curate.ts:20-32` ALL_SLIDES; `book/presentation-shell.ts:587-591` BUILDERS map;
   `presentation-shell.ts:1` "Renders a 10-slide brand book").
3. **`wb` is never invoked** — `composeBookData → bundleWorkbook → renderPresentation` hand-roll a
   `wb-source-bundle` script (`presentation-shell.ts:207-209`) with **no `data-version`**, so
   `wb unbundle` rejects every book (`forge .../unbundle.mjs:38-43` hard-fails unless `data-version==1`).
4. **Media collection is a no-op stub** (`book/pipeline.ts:445-452`); `with_video`/`link_only` are
   passthrough TODOs (`pipeline.ts:451`).

### The wow-moment we are building
An **agent works a BOARD — one task per page** — and drives the book to completion through a
deterministic, LLM-free orchestration loop (`runtime/engine/.../board.ex`). For each page the agent
**self-validates** before advancing: a **vision pass** (creative-vision / Gemini over the rendered
slide), an **OQL-queryability** check (the page's `.org` headlines + `:PROPERTIES:` return rows), and a
**packaging** check (`wb bundle`/`wb unbundle` round-trips with `data-version="1"`). The output is a
single-file `.html` presentation that is genuinely queryable, genuinely round-trippable, and backed by
REAL brandnana data — not a static template stub. The headline demo: *"point the agent at a domain,
walk away, come back to a brand book — as long as the data warrants — where every fact is a query and
every page passed three gates."*

---

## 1b. Build Model — Generative Authoring, NOT Templating

The book is **not** a fixed-N template the agent fills in. It is **generatively authored**: page count and
structure are **data-driven and dynamic**. A brand with 10 distinct ad trends gets 10 ad pages; one with
2 gets 2; a product-heavy brand gets an expanded go-to-market section. The agent reasons about the data,
forms an editorial thesis, and crafts each page **with intention and deliberation**, validating as it goes
— the opposite of declarative structured output. Five stages:

1. **Research substrate (deterministic pre-run, §5).** Gather ALL data → a complete org + R2 substrate.
2. **Editorial planning (the deliberation).** A *director/editor* agent reads the WHOLE substrate and
   authors an **editorial outline + thesis**: what story this brand tells, which chapters matter, where to
   **pivot** (weak Meta ads → emphasize LinkedIn; deep catalog → expand go-to-market per product line),
   and how to **paginate** (cluster ads/products/posts into N distinct trends → N pages). It emits the
   board's page-tasks **dynamically** (could be ~30, could be ~150), each task carrying an *editorial brief*
   (the argument the page makes + its data slice + its media), not just a template id.
3. **Page authoring board (deliberate per page + deterministic orchestration).** The board runs the
   generated tasks. Each page → a sub-agent that researches its slice, **authors** the narrative +
   queryable org + slide composition with intention, then passes the three gates (vision / OQL / packaging).
   Verified-bad work is abandoned (worktree never merged).
4. **Editor review (reflexion / second pass).** A review agent does a holistic vision + coherence pass over
   the full deck — flow, redundancy, gaps — and can spawn a **second board run** to add/revise/deepen
   pages. This is how the book intentionally "balloons" when the research warrants it.
5. **Package + publish.** Compile the `data-version="1"` bundle, final `wb build`/`wb unbundle` round-trip
   → the queryable org workbook.

**Framework constraint (honest).** The deterministic `WorkbooksRuntime.Board` runs a *declared* task set per
run; dynamic growth WITHIN a single run (recursive self-spawning) is unbuilt (BOARD-V2 recursive model,
`BOARD-V2-RECURSIVE-MODEL.org:157-161`). So dynamic sizing happens at **stage 2** (the editor authors the
task set from the data) and via **stage 4 second-pass runs** — exactly the "we can always have a second
pass" iteration described. The §3 outline below is therefore a **SEED scaffold** (the chapter spine +
the data→section mapping), NOT a fixed page list; the editor expands/contracts it per brand.

---

## 2. PRE-RUN Data-Sources Table

Goal: run ALL data BEFORE the agent composes, so the agent starts from a complete `.org` substrate and
only does composition + per-page self-validation. Citations are `file:line` in
`projects/brandnana/apps/api/src/verbs.ts` and the CLI commands, with LIVE status from `AUDIT.md`.

| # | Verb / CLI | Input | Output shape | Fills (book sections) | Media yield | Vendor / cost | LIVE? |
|---|---|---|---|---|---|---|---|
| 1 | `resolve.query` (`brandnana resolve`) | brand name / ambiguous ref | `{candidates[{domain,confidence}], recommended}` | Cover, identity anchor; seeds every downstream verb | none | Valyu + OpenRouter LLM fallback (`verbs.ts:396-410`) | **YES** |
| 2 | `brand.fetch --include all` (palette/fonts/styleguide/screenshot) | domain | `{brand: NormalisedBrand, extras:{fonts,styleguide,screenshot_url}}` | Identity, Palette, Typography, Logo, Tagline, Voice, Socials | homepage screenshot + logo URL | context.dev ~$0.001 (`verbs.ts:95-169`) | **YES** (browser-render enrich tier broken→radii/spacing null) |
| 3 | logo cascade (`brandnana logo`) | domain | `{candidates: LogoCandidate[], recommended}` (5-tier) | Logo / wordmark page | SVG/PNG logo bytes (embed inline) | CONTEXT_DEV_API_KEY (`verbs.ts:187-206`) | **YES** |
| 4 | `brand.company` (firmographics) | domain | `{industry, employee_range, location, founded, NAICS/SIC}` | Identity `:PROPERTIES:` (FOUNDED/HQ/CATEGORY/LEGAL) | none | The Companies API (`verbs.ts:170-183`) | **NO — orphan key** THE_COMPANIES_API_KEY, zero consumers (`AUDIT.md:104,191`) |
| 5 | `social.*` (98 verbs, IG/TikTok/YT/X/FB/LinkedIn/…) | handle / url | `{summary: ProfileSummary(followers,bio,counts), posts/reels/videos}` | Social presence, follower stat cards, post/reel imagery | post images, reel/video thumbs + URLs | ScrapeCreators ~$0.001 (`verbs.ts:412-1562`) | **YES** (live-verified: nike 291,995,462 followers) |
| 6 | `ads.search --source all` | query, source, brand | `{ads: NormalisedAd[{ad_headline,landing_url,media_url,media_type}]}` | Campaigns/ads, competitor ads | ad creative images + video URLs | ScrapeCreators ad libs (`verbs.ts:210-236`) | **PARTIAL** (ScrapeCreators legs live; Exa leg dead-but-silent; Meta Graph needs META_GRAPH_TOKEN `AUDIT.md:88-90`) |
| 7 | `ads.google --brand` | brand name | `{advertiser_id, advertiser_url, creative_ids}` | Google-ads / competitive ad landscape | creative_ids → fetch → R2 | ScrapeCreators + Firecrawl (`verbs.ts:291-309`) | **YES** |
| 8 | `catalog.crawl --mirror` (NDJSON stream) | domain, strategy, max_urls | `CatalogRow{product|product_image|stats}` (name,sku,price,sizes,colors,images,…) | ENTIRE product catalog page-set (5 indices) | product images (many) → R2-mirror | Shopify→context.dev→sitemap→Firecrawl (`verbs.ts:313-340`; mirror `catalog.ts:144-201`) | **YES** (real streaming crawler; isShopify demotes transient fails) |
| 9 | `design.tokens` | domain | `DesignTokens{palette,fonts,voice, radii:null, …}` | Machine-readable design-tokens page | none | context.dev (`verbs.ts:379-392`) | **YES** (radii/spacing/gradients null) |
| 10 | `brief.get` | domain, handle | `BriefResult{brand,design,social,ads,errors[]}` (9-call fan-out) | Fast first-pass pre-fetch (NOT a validation source) | aggregates screenshot+social+ad media | context.dev+ScrapeCreators (`verbs.ts:356-375`) | **PARTIAL** (null legs swallowed to empty 200s) |
| 11 | creative analyze (`brandnana creative analyze`) | `{kind,urls[],poster_url?}` | `CreativeAnalysis{hook,subject_focus,mood,palette[],text_overlays[],cta_visible,…}` | Ad-creative analysis pages; **doubles as the vision self-check** | consumes media (yields none) | OpenRouter maverick (stills) / Gemini (video) (`creative.ts:14`) | **stills YES; video NO** without GEMINI_API_KEY (poster-frame fallback) |

---

## 3. The ~42-Page Board Design (Chapters → Pages → Task + Data Source + Gate)

The board is a directory of `.wb-orch/tasks/<page-NN>.json` files (one per page) plus `agents.json`,
driven by `WorkbooksRuntime.Board` (`runtime/engine/lib/workbooks_runtime/board.ex:1-49`). Each page-task
carries `acceptance[]` check specs (the per-page gate) and `blocker[]` edges (ordering). Acceptance
specs are `command:<shell>` (exit 0 = pass) or `artifact:<abs-path>` (file exists), evaluated by
`Board.Acceptance.check` — ALL must pass before `:done`
(`runtime/engine/.../board/acceptance.ex:1-80`; `board/dispatcher.ex:136-176,229`).

LEGEND: **EXISTS** = a current slide builder already produces it (11 of 42); **wired-from-template** = a
template/verb is designed but the old book pipeline never invokes it (~14 sections); **NEW** = greenfield
editorial/guideline design, no current data (~10 sections, mostly dos-and-donts/audience/positioning).

Per-page gate columns: **V** = vision pass (`creative analyze` over the rendered slide PNG);
**Q** = OQL query returns expected non-empty rows; **P** = packaging (page `.org` is in the
`data-version="1"` bundle and round-trips). Every page asserts all three; the table notes the page's
*primary* query.

### CH I — IDENTITY (5)
| Pg | Title | Source | Status | Primary OQL gate |
|----|-------|--------|--------|------------------|
| 1 | Cover | `resolve.query` + curated headline | EXISTS (slideCover) | headline non-empty |
| 2 | Brand-at-a-glance / identity card | `brand.fetch` | EXISTS (slideIdentity) | `tags CONTAINS brand` → DOMAIN/CATEGORY/TAGLINE present |
| 3 | Logo & wordmark + clear-space | logo cascade (`logo-fetch.ts`) | wired-from-template | `*** Logo` has PRIMARY_URL/SVG_PATH |
| 4 | Logo misuse / dos-and-donts | derive from logo+palette | NEW | logo-rule headlines exist |
| 5 | Brand story / positioning statement | `brand.description` + style_signal | wired (needs richer copy) | story body non-empty |

### CH II — VOICE & MESSAGING (4)
| 6 | Voice principles | curated `voice_notes` | EXISTS (slideVoice) | `** Voice` ≥3 notes |
| 7 | Tone spectrum / register | voice_notes + ad_lines | NEW | tone-axis headlines |
| 8 | Tagline & key messages | `brand.tagline` + ad headlines | wired | TAGLINE present |
| 9 | Lexicon: words we use / avoid | derive from corpus | NEW | lexicon rows |

### CH III — AUDIENCE (3)
| 10 | Who we talk to / personas | social demographics + firmographics | NEW (no data today; see OPEN DECISION 5) | persona headlines |
| 11 | Customer mindset / jobs-to-be-done | agent editorial | NEW | jtbd rows |
| 12 | Where they are (channel map) | `brand.social` + social coverage | wired | channel rows |

### CH IV — MARKET & COMPETITORS (5)
| 13 | Competitive set overview | `brand.competitors` | EXISTS (slideCompetitors) | competitor rows >0 |
| 14 | Competitor deep-dive A | `COMPETITOR_TEMPLATE` (`templates.ts:80-123`) | wired-from-template (needs brand-fetch per competitor) | competitor A props |
| 15 | Competitor deep-dive B | same | wired-from-template | competitor B props |
| 16 | Palette/visual deltas vs competitors | `COMPETITOR_TEMPLATE` palette_distance/tone_delta | wired-from-template | delta props present |
| 17 | Positioning map / white space | agent editorial | NEW | positioning rows |

### CH V — SOCIAL (5)
| 18 | Social footprint overview | `brand.social` | EXISTS (slideSocial) | platform rows >0 |
| 19 | Per-platform profiles & metrics | `social.*` profile verbs | wired-from-template | FOLLOWERS per platform |
| 20 | Top posts / content pillars | `social.*` posts verbs | wired-from-template | post rows >0 |
| 21 | Engagement & cadence | `social.*` metrics | wired-from-template | metric props |
| 22 | Video / reel signal | `social.*` reel/transcript verbs | wired-from-template | reel rows |

### CH VI — ADS & CREATIVE (5)
| 23 | Campaign overview | `brand.ads` | EXISTS (slideAds) | ad rows >0 |
| 24 | Live ad gallery (Meta/Google) | `ads.search` + `ads.google` | wired-from-template | AD_ID/MEDIA_URL present |
| 25 | Ad creative analysis (theme/emotion/hook) | creative analyze → `COMPETITOR_TEMPLATE:118-121` | wired-from-template | THEME/EMOTION/HOOK props |
| 26 | CTA & landing patterns | `AdRecord.cta/landing_url` (`types.ts:58-73`) | wired-from-template | CTA/LANDING_URL props |
| 27 | Creative dos-and-donts | agent editorial | NEW | rule rows |

### CH VII — PRODUCT / CATALOG (6)
| 28 | Catalog overview / counts | `PRODUCTS_TEMPLATE` (`templates.ts:125-192`) + crawler | wired-from-template (rewire crawler) | product_count >0 |
| 29 | By-category index | PRODUCTS_TEMPLATE by-category | wired-from-template | `index:category` rows |
| 30 | By-collection index | by-collection | wired-from-template | `index:collection` rows |
| 31 | By-color index | by-color | wired-from-template | `index:color` rows |
| 32 | By-price-band index | by-price-band | wired-from-template | `index:price-band` rows |
| 33 | Hero products / bestsellers | products array | EXISTS (slideCatalog, first 6) | product PRICE rows |

### CH VIII — DESIGN SYSTEM / TOKENS (5)
| 34 | Color system + roles | curated `palette_roles` | EXISTS (slidePalette) | swatch rows |
| 35 | Extended palette + hex/usage | `BRAND_TEMPLATE` extended_colors (`templates.ts:49-53`) | wired-from-template | HEX per swatch |
| 36 | Typography system | `brand.primary/secondary_font` | EXISTS (slideType, 2 samples) | PRIMARY_FONT present |
| 37 | Type scale & hierarchy | extend type_samples | NEW | scale rows |
| 38 | Design tokens export | `design.tokens` / `brand.styleguide` verb (`verbs.ts:130`) | wired-from-template (degraded) | token rows |

### CH IX — APPLICATIONS (2)
| 39 | Homepage / web presence | `extras.homepage_screenshot` + style_signal | EXISTS (slideHomepage) | screenshot present |
| 40 | In-context mockups | generated imagery (`make-image.org`) | NEW | mockup rows |

### CH X — GUIDELINES & PROVENANCE (2)
| 41 | Usage guidelines summary | synthesize logo/color/type/voice rules | NEW | guideline rows |
| 42 | Capture provenance / sources / data-version | `timeline.org` verb-trace | EXISTS (slideTimeline) | event rows (VERB/STATUS/VENDOR_COST) |

**Totals:** I-5, II-4, III-3, IV-5, V-5, VI-5, VII-6, VIII-5, IX-2, X-2 = **42**.
~11 EXISTS + ~14 wired-from-template + ~10 NEW (editorial). ~25 of 42 sections are backed by data that
already exists on the brandnana surface; only ~10 are genuinely greenfield, and most of those are
editorial guideline pages, not data pages.

**Board topology:** a shared `gather-org-data` task (the pre-run sweep, §5) is the common `blocker` for
all page-tasks, so pages build in parallel up to the board concurrency cap once data lands. Sequential
chapters can additionally chain `blocker:[page-(N-1)]`. A `compile-bundle` task `blocker`s on all 42
pages and runs the final `wb build`/`wb unbundle` packaging gate.

---

## 4. The Agent Build LOOP (per page) with `wb` Commands

The mechanical Board loop (`board.ex:154-225`) is: pick ready → claim (O_EXCL lockfile,
`claim.ex:1-110`) → dispatch to a worktree-isolated sub-agent → on `{:task_complete}` run the acceptance
gate → if all specs pass, advance disk state to `:done` + cascade `trigger` edges (`board.ex:285-296`,
`sync.ex:30-47`); if any gate fails, mark `:cancelled` + cascade dependents to `:blocked`. Per page the
sub-agent does:

1. **Claim** — automatic via the Board's atomic lockfile; the agent never touches git.
2. **Render the page** — compose the slide and emit the queryable `.org` for the page, then render the
   single-slide PNG. `wb dev` / `wb build` drive the forge toolchain (`cli/wb/src/cmd/workbook.rs`).
3. **Vision pass** — `command:` spec runs `brandnana creative analyze --url <rendered-slide.png>
   --kind image --json` (OpenRouter maverick for stills; Gemini if video). Gate = analysis returns a
   coherent `subject_focus`/`mood` with no `error` (exit 0). This is the creative-vision check from
   `creative-vision.ts:15-34`.
4. **OQL-queryable check** — `command:` spec runs `wb workbooks query` (or `wb query`) over the page's
   `.org` asserting the expected headlines/properties exist and are non-empty, e.g.
   `SELECT title,PRICE FROM headlines WHERE tags CONTAINS product` → rows >0. OQL reads the
   `wb-source-bundle`, not the rendered HTML (`runtime/engine/.../oql/extract.ex`,
   `oql/headlines.ex:1-55`).
5. **Packaging check** — `command:` spec runs `wb build` then `wb unbundle` on the artifact and asserts
   the round-trip succeeds and the bundle carries `data-version="1"` and an accurate
   `data-file-count`. (`forge .../embedSource.mjs:8-16` schema; `unbundle.mjs:38-43` requires
   `data-version==1`.) An `artifact:/abs/page-NN.png` spec asserts the rendered slide exists.
6. **Mark done** — only when V + Q + P all pass does `Board.Acceptance.check` return `:ok` and the Board
   advances the page to `:done`. Verified-bad work is abandoned (the worktree is never merged,
   `dispatcher.ex:148-150`). An external autoloop wrapper then commits the on-disk state advance
   (message `advance task/page-NN`, body `Why: state → done`) — note the engine Board writes state JSON
   but does NOT git-commit (the commit discipline is the worg-agent/autoloop layer, not the engine).

Board run command: `wb board run <BOARD_DIR> --worktree-repo <repo> --target-branch main
--concurrency N` → POSTs `/api/run-plan` (`cli.rs:1542-1577`; `agent_controller.ex:98-150`).
Status: `wb board status <BOARD_DIR>` → GETs `/api/board`.

---

## 5. PRE-RUN Orchestration (run once per brand, dependency-ordered)

A single deterministic sweep (the `gather-org-data` blocker task) writes the brand workspace
(org files + local SQLite + an R2 media prefix) BEFORE any page is composed:

- **Stage 0 — Resolve (blocking, gates all):** `brandnana resolve <input>` → canonical domain. (LIVE)
- **Stage 1 — Brand core (parallel on domain):** `brand.fetch --include all` → `brand.org`;
  logo cascade → embed SVG; `design.tokens` → `design-tokens.org`; `brand.company` → firmographic
  props (NEEDS-A-KEY: orphan THE_COMPANIES_API_KEY — mark `status=needs_key` in `timeline.org`, do not
  emit a green stub). (LIVE except company)
- **Stage 2 — Catalog (slowest, run early in background):** `brandnana catalog crawl <domain> --mirror`
  → streams products+images into SQLite, mirrors images to R2 → `catalog/products.org` with all 5
  indices. This is the leg the old pipeline stubbed to 0. (LIVE)
- **Stage 3 — Demand signals (parallel):** `social.*` profiles+posts+reels per platform →
  `social/<platform>.org` + R2-mirror thumbs; `ads.search --source all` + `ads.google` → `ads.org` +
  R2-mirror creatives. (LIVE for ScrapeCreators legs)
- **Stage 4 — Competitors (fan-out per competitor):** resolve→brand.fetch→ads.search →
  `competitors/<slug>.org`. (LIVE)
- **Stage 5 — Creative vision over harvested media:** pooled
  `brandnana creative analyze --concurrency 12` over ad+hero+product creatives → write
  hook/mood/subject_focus back into the relevant org `:PROPERTIES:`. (LIVE stills; video needs
  GEMINI_API_KEY)
- **Stage 6 — Provenance (as-you-go):** every verb outcome (ts, verb_id, status, duration, vendor_cost,
  error) appended to `timeline.org` as it runs — the queryable capture trace.

After the sweep, the org workspace + R2 prefix is the COMPLETE substrate; the board's 42 page-tasks then
compose + self-validate against it.

---

## 6. Media Policy (R2 vs Embed-Compressed) per Type, with Size Budget

The framework does NOT transcode media — there is no webp/avif/ffmpeg/squoosh/sharp anywhere in
`cli/wb`, runtime, packages, or substrates. Its only "media-compression" is (a) gzip over the text
source bundle and (b) raw base64 inlining of binary blobs (`workbook-bundler/src/bundle.rs:17-46`).
So the agent must PRE-ENCODE delivery-ready media before handing bytes to `wb`.

**Two storage lanes:** Lane 1 = gzipped JSON source bundle (text: org files, source, small SVG/PNG).
Lane 2 = `InlineBlob` — each binary gets its own `application/octet-stream;base64` script tag, base64
once, no gzip pass (gzip inflates entropy-dense media ~1-2%). R2 path: content-addressed sha256 keys in
`brandnana-assets` bucket, immutable 1-year cache, served at `https://api.brandnana.net/`
(`wrangler.toml:28-30`; mirror `mirror/routes.ts` 8MiB/image cap, global dedup; generated assets
`image-gen.ts:142-157`).

**Size budget:** single `.html` should stay well under the documented ~25MB inline guideline
(`packageWorkbook.ts:5-7`; the only enforced gate is a 1MB inline-extract threshold). Base64 adds 33%,
so the real inline media budget is **~12-15MB of source bytes** (leaving room for WASM runtime + source
bundle). The packaging gate should assert an explicit total `.html` size cap (~15-20MB) because the
framework will not stop over-inlining.

| Media type | Policy | Rationale |
|---|---|---|
| Logos (SVG) | **EMBED inline** | text, rides the gzip source bundle, tiny |
| Logos (PNG) + 1-2 hero/key images (<~200KB each, pre-encoded) | **EMBED inline** (raw-base64 InlineBlob) | small, within budget |
| Homepage/product screenshots + many product images | **R2 link** (`https://api.brandnana.net/...`) | too numerous/large; reuse mirror dedup |
| Ad creatives (images + carousels) | **R2 link** | carousels multiply count fast |
| All videos (ad/reel) | **R2 link, never inline** | no video compressor (Theater render is a stub, `index.ts:91`); one 5-20MB clip + base64 dominates the file |

Net shape: a **thin single-file `.html`** (logos + key images inline, all queryable org data in the
gzip bundle) that REFERENCES the bulk of product/ad media and ALL video by R2 URL. OQL should index
media as queryable rows carrying their R2 URL / inline-blob id (so "all ad creatives for brand X"
returns R2 links).

---

## 7. Technical Shape

- **Render:** `type: presentation` — `wb-slide` sections with archetype classes; `wb check` is a
  headless per-slide lint (overflow, missing-archetype, palette-drift, near-duplicate, unstyled-slide).
  42 pages = 42 slides + 42 headlines. The old shell caps near 10 fixed slides
  (`presentation-shell.ts:405-568`); the new book extends/replaces the builder set so the slide count is
  data-driven, not a fixed BUILDERS map.
- **OQL-queryable org structure:** every queryable fact is an org headline and/or a key in its
  `:PROPERTIES:` drawer, with meaningful `:tags:`. The runtime extracts the `wb-source-bundle`
  (`oql/extract.ex`, `@supported_versions=[1]`) and normalizes headlines into
  `{id, document_path, level, title, tags, properties{}}` (`oql/headlines.ex:1-55`). Conform to the four
  existing templates: `brand.org.template`, `products.org.template`, `competitor.org.template`,
  `timeline.org.template` (verified present), plus new `social/*.org` and `design-tokens.org`.
- **Packaging (data-version):** queryable org files go in
  `<script id="wb-source-bundle" type="application/x-workbook-source" data-format="json+gzip+base64"
  data-version="1" data-file-count=N>` (`embedSource.mjs:8-16`). This is the exact thing the old
  pipeline omitted (`presentation-shell.ts:207-209`), causing every `wb unbundle` to fail
  (`unbundle.mjs:38-43`). The compile-bundle task MUST emit `data-version="1"` + accurate
  `data-file-count`, then prove the round-trip.
- **Runtime variant + size estimate:** `wasmVariant: none` (presentation needs no Polars/Candle/SQLite
  WASM) → ~150KB runtime. Plus source bundle (42 org files, gzipped: small, low-100s of KB) + inline
  media (logos + a few heroes, budgeted <~12-15MB). **Estimated single-file `.html`: ~1-4MB typical**
  (mostly inline hero images), well under the 25MB guideline, with bulk media on R2.

---

## 8. Validation Checklist (green / yellow / blocked)

- **GREEN (data is live, mechanism exists):** resolve, brand.fetch/palette/fonts/styleguide/screenshot,
  logo cascade, social.* (98 verbs), ads.search (ScrapeCreators legs), ads.google, catalog.crawl
  --mirror, design.tokens, creative analyze (stills). Board orchestration (board.ex, claim.ex,
  acceptance.ex), OQL extract+headlines, presentation render, `data-version` bundle schema, R2 mirror
  path. ~25/42 sections data-backed.
- **YELLOW (live but degraded / needs care):** brand.fetch browser-render enrich tier broken
  (radii/spacing/gradients null); brief.get swallows null legs to empty 200s (use as pre-fetch only,
  not a validation source); isShopify demotes transient failures to 12-product context.dev; ads Exa
  discovery leg dead-but-silent. ~10 NEW editorial pages (audience/dos-donts/positioning/lexicon) have
  no backing data and are agent-authored — acceptable but flagged as editorial, not factual.
- **BLOCKED (needs a key or a build decision before run):** brand.company firmographics
  (THE_COMPANIES_API_KEY orphan, zero consumers — page must be built or dropped); video creative
  analysis (GEMINI_API_KEY absent → poster-frame fallback); official Meta Ad Library
  (META_GRAPH_TOKEN, 503 until approved); old pipeline rewire — catalog 0-stub must be replaced by the
  real crawler call, `wb` must actually be invoked, bundle must stamp `data-version`.

---

## RETURN

### Executive Summary (12 lines)

1. The "42-page brand book" is an unbuilt marketing promise; today's pipeline ships ≤11 slide types, a 0-product catalog stub, no `data-version`, and never invokes `wb`.
2. Wow-moment: an agent works a BOARD (one task per page) and self-validates every page on three gates — vision (creative-vision/Gemini), OQL-queryability, and `wb` packaging — before advancing.
3. Orchestration is the deterministic, LLM-free `WorkbooksRuntime.Board`: claim (O_EXCL) → dispatch to worktree-isolated sub-agent → run acceptance gate → advance + cascade.
4. Each page-task declares `acceptance[]` = `command:` checks (vision pass, OQL query returns rows, `wb build`/`wb unbundle` round-trip) + an `artifact:` slide PNG; ALL must pass for `:done`.
5. A PRE-RUN sweep (resolve → brand core → catalog → social/ads → competitors → creative-vision → provenance) writes the COMPLETE org + R2 substrate before any page is composed.
6. ~25 of 42 sections are backed by live brandnana data (brand/logo/palette/fonts/social/ads/catalog/design-tokens/creative); ~10 are greenfield editorial pages (audience/dos-donts/positioning).
7. Queryability = org headlines + `:PROPERTIES:` drawers + tags, extracted from the `wb-source-bundle` (NOT the HTML); conform to the 4 existing templates + new social/design-token org files.
8. Packaging fix = emit `data-version="1"` + accurate `data-file-count` so `wb unbundle` and `wb query` both succeed (the two things the old bundle failed).
9. Media: framework does NOT transcode — pre-encode, then EMBED logos/SVG + 1-2 heroes inline; R2-link all product/ad images and ALL video; inline budget ~12-15MB source bytes; assert a ~15-20MB `.html` cap.
10. Render shape: `type: presentation`, `wasmVariant: none` (~150KB runtime); estimated single-file `.html` ~1-4MB with bulk media on R2.
11. Blocked-until-decided: catalog crawler rewire scope, firmographics orphan key, video Gemini key, official Meta Ad Library token.
12. This is a PLAN only — no code written; build proceeds once the OPEN DECISIONS below are locked.

### OPEN DECISIONS (lock before build)

1. **Page count / outline source.** Is **42** a hard requirement, or is the audit's offer to "re-scope and drop the 42-page claim" (`PROMISES.md:216-217`) on the table? The proposed outline lands exactly on 42, but ~10 sections are editorial design work with no backing data. Approve the §3 outline as canonical, or set a different target (e.g. ~30 all-data-backed pages).

2. **Presentation vs. document model.** Build as a **presentation** (slide-per-page, extending `presentation-shell.ts` builders) or a **document** (long-form, using the unused `document-shell.ts` widget vocabulary, which maps more cleanly to 42 sections and to the "one task per page" framing)? Plan assumes presentation; confirm or switch.

3. **Catalog crawler rewire scope.** The 6 catalog pages depend on wiring `fetchCatalogData` to the real Shopify crawler (`catalog.crawl --mirror`), currently a 0-product stub (`pipeline.ts:334-364`). Is that rewire IN SCOPE for this board build, or do those 6 pages gracefully degrade when `product_count==0`?

4. **Media default policy + R2 prefix.** Confirm the default = logos/SVG + 1-2 heroes inline, everything else (product/ad images + all video) on R2 via `https://api.brandnana.net/...`. Confirm the R2 bucket/prefix the catalog `--mirror` writes to is the SAME store the agent references for ad + social media (the ad/social prefix is not yet defined in code). Confirm the `.html` total-size cap to enforce (proposed ~15-20MB).

5. **Audience chapter data.** Sections 10-12 have NO current data source. Source personas from social follower demographics + THE_COMPANIES firmographics (orphan key, zero consumers), or treat audience as **agent-authored editorial** for v1?

6. **Blocked keys / degraded sources.** For v1: (a) drop or mark `needs_key` the firmographics page (THE_COMPANIES_API_KEY)? (b) accept poster-frame video analysis or provision GEMINI_API_KEY first? (c) use the live ScrapeCreators Meta-library scrape and defer the official Meta Graph Ad Library (META_GRAPH_TOKEN)?

7. **Competitor depth.** Sections 14-17 need real per-competitor brand-fetch + ads.search (the old pipeline only emits competitor names). How many competitors deep per book, given cost/latency budgets?

8. **Board location + single-brand vs. template.** Does the board live IN the brand workspace dir (`.wb-orch/` alongside the org files) or in a separate orchestration repo? And is this board a **single-brand one-shot** or a reusable **template** parameterized by domain (the `wb agent dispatch` scaffold pattern, `cli.rs:1461-1538`, emits a one-task board — confirm whether we generalize it to emit all 42 page-tasks programmatically)?

9. **Multi-stage per page vs. chained tasks.** Board v2's full per-state machine (draft→render→vision→OQL→bundle as states) is explicitly unbuilt (`BOARD-V2-RECURSIVE-MODEL.org:157-161`). Confirm we model any multi-step page as the single-gate acceptance with multiple `command:` specs (plan's assumption), NOT as chained blocker tasks or the unbuilt state-machine interpreter.

10. **Commit discipline + manager approval.** Confirm the external autoloop wrapper commits one `advance task/page-NN` per page after its gate passes (the engine Board does not git-commit), and whether the board policy sets `:APPROVAL: manager` (soft human/agent approval after the deterministic gates) or `none`.
