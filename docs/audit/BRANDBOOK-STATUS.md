# Brandnana Brand-Book — Build Status

_Last updated: 2026-06-04 · Branch: `brandnana-remediation-p0` · Not committed/deployed._

This is the load-bearing status for the **brand-book product**: the layers built
**on top of** the proven Stage-1 substrate (Brand Scout harvest → deterministic
`brandnana substrate build`/`check`/`publish` → a 5/5-validated, queryable OQL
org substrate with 1358 products, social/ads/brand/provenance orgs, media on R2).

The architecture is unchanged and intact: **the LLM only GATHERS; the render is
deterministic.** Stage-2 (analysis) is the one intentional exception — the
strategist's *reasoning* is the value, so only its **gate** is deterministic, not
its authoring.

---

## 1. End-to-end pipeline status

Legend: **DONE** = real + compile-clean + proven · **WIRED-FOUNDATION** =
plumbing is real and verified, but the data-driven authoring/rendering on top is
the agent's runtime job (design-heavy, flagged) · **NEEDS-BUILD** = not built.

| Stage | Status | What is REAL now (verified) | What remains |
|---|---|---|---|
| **Harvest** (Stage-1) | **DONE** | Multi-tenant `bn-engine` harvest → `brandnana substrate build`/`check`/`publish` → faithful 5/5-validated OQL org substrate (`brand.org`, `catalog/products.org` [1358], `social/*.org`, `ads.org`, `harvest-provenance.org`); media on `api.brandnana.net/assets` R2. Deterministic render; LLM only gathers. | — (per-event margin ledger gap is internal-only; see §3.5) |
| **Analysis** (Stage-2 gate) | **DONE** (gate) | `brandnana analysis check [workdir]` is real, wired (`apps/cli/src/index.ts:4,79`), and **fail-loud-proven**. `validateAnalysis()` (`analysis-check.ts:447`) runs 4 checks + structural guards. Verified live: grounded substrate + all 7 required types → **PASS exit 0**; one dangling citation → **FAIL exit 1** naming the ghost point. CLI: `tsc --noEmit` exit 0; 83/83 tests pass. | Analysis **quality** (insightful vs merely-true) is the strategist's runtime job — see §3.1. Testimonial-quote byte-provenance not yet asserted — §3.2. |
| **Analysis** (Stage-2 authoring) | **WIRED-FOUNDATION** | Schema contract shared: `skills/write-analysis.org` (the `:insight:`+`:TYPE:`+`:GROUNDS:` shape, anchor forms, discovery recipe). Strategist rewritten (`agents/brandnana-strategist.org`) to read checked substrate → reason → write `analysis/*.org` → DONE = `analysis check` PASS. Header intact (`:TOOLKITS: bash wb brandnana`, `:CAN_GRANT:`). | The LLM actually emitting grounded, high-quality `analysis/*.org` at runtime — §3.1. |
| **Deck-bundle** (Stage-3) | **DONE** (the audit fix) | `renderSourceBundleScript()` (`book-bundle.ts:54`) is the single source of the `wb-source-bundle` tag and now emits **`data-version="1"`** (`:60`) — the field the OLD tag omitted, which made `unbundle.mjs:38` hard-reject every book. Wired into all 3 shells (`presentation-shell.ts:212`, `document-shell.ts:236`, placeholder shell). Round-trip proven against forge's own parsers (version=1, fileCount, manifest incl. `analysis/*.org` decode byte-for-byte). API `tsc` exit 0; 17/17 book tests pass. | **Data-driven slide composition** — deck is still a fixed template; org→slide mapping FROM `analysis/*.org` is unbuilt — §3.3. |
| **Board** (seam) | **WIRED-FOUNDATION** | Runtime-enforced 3-stage DAG: `gather-org-data` → `author-analysis` → `compose-deck` (`boards/brand-book/tasks/*.json`, valid JSON, matching `Loader.Task` wire schema). Real `acceptance[]` gates: author-analysis → `command:brandnana analysis check .`; compose-deck → `artifact:book.html` + `wb unbundle` round-trip assertion. Both assigned to `brandnana-strategist` with `[bash,wb,oql]`. | **Dynamic per-page board growth** (PLAN §1b stages 2/4 — editor authors N page-tasks from data) is unbuilt; today's board is the fixed 3-stage spine — §3.4. |
| **Publish** (serve) | **DONE** | `POST /v1/book` writes the standalone `.html` to `brand-books/public/<slug>.html` (`routes.ts:203,207`); `serve.ts:38` `GET /books/:filename` returns it as `text/html` with `frame-ancestors *` for the lander iframe. The bytes served are the fixed-tag bundle, so `https://api.brandnana.net/books/<slug>.html` both renders AND `wb unbundle`s. | **Private `.html` serve has no producer** — `serve.ts:65` reads `brand-books/private/...` but only the public path writes `.html` — §3.6. |
| **Query** (book-as-backend) | **WIRED-FOUNDATION** | `skills/query-book.org` uses the canonical `wb workbook query <file> "<oql-sexpr>"` form (backed by `Oql.Extract.from_html`); every eval ask maps to a real OQL s-expr (`(and (tags insight) (title ~ voice))` etc.). Bundle packages the full org workspace, so `analysis/*.org` rides into the book and is `wb query`-able after unbundle (confirmed in round-trip). | **No published brandnana book has been queried end-to-end yet** — depends on the strategist actually authoring tagged `analysis/*.org` at runtime — §3.4.2. `brandnana book list` discovery verb assumed — §3.4.4. |

---

## 2. What this push WIRED (the real foundations built)

1. **The Stage-2 grounding gate (`brandnana analysis check`)** — created
   `apps/cli/src/commands/analysis-check.ts` (modeled exactly on sibling
   `substrate-check.ts`), wired at `apps/cli/src/index.ts:4,79`. Four checks +
   structural guards:
   - `grounds_present` (`:300`) — every `:insight:` has a non-empty `:GROUNDS:`.
   - `grounds_resolve` (`:334`) — **every citation resolves to a real Stage-1
     anchor; dangling citations rejected.** Anchors built from the actual
     substrate (`collectSubstrateAnchors`, `:189`): `:ID:`/`:AD_ID:`/`:HANDLE:`/
     `:POINT:` plus `<file-stem>:<tag>` for non-structural tags.
   - `coverage` (`:365`) — requires 7 core types (voice/tone/audience/
     positioning/messaging-pillars/copy-ideas/ad-ideas); flags unknown TYPEs.
   - `substance` (`:390`) — rejects skeleton insights (<40 char body).
   - Non-zero exit on any failure; `--json` and human modes both work.
   **Proven live this push:** grounded + all-7-types → `RESULT: PASS` exit 0;
   adding one dangling citation → `RESULT: FAIL` exit 1, `grounds_resolve` line
   `dangling citation "ghost-point-404"`.

2. **The `data-version="1"` bundle fix** (the core audit bug) — centralized in
   `renderSourceBundleScript()` (`book-bundle.ts:54-65`), wired into all three
   worker-side shells. The OLD inline tag omitted `data-version`, so
   `unbundle.mjs:38` (`meta.version !== "1"`) rejected every book. Now one helper
   so it can't drift. Round-trip proven against forge's real
   `readBundleMeta`/`extractBundle`/`decodeBundle` + the `unbundle.mjs:38-52`
   gates.

3. **The board seam** — `author-analysis.json` + `compose-deck.json`: a
   runtime-enforced harvest→analysis→deck DAG with deterministic acceptance
   gates (`analysis check` PASS; `wb unbundle` round-trip).

4. **The query path** — `skills/query-book.org` + `skills/book.org`: the
   canonical `wb workbook query` interface; every eval ask → a concrete OQL
   s-expr in the dialect the harvest gate already uses; answers carry `:GROUNDS:`
   receipts so a grounded query can't dangle.

5. **Stub/TODO sweep** (non-book api/src + packages) — **0 silent dead-ends.**
   Every hit resolved to explanatory comments, correct fallbacks, or honestly-
   scoped deferrals. `gateway.ts` dead module and e2b/sandbox remnants do **not**
   exist as code (already removed; only vendor-list comments remain). `schema`
   package typechecks clean.

**Verify (this push):** CLI `tsc --noEmit` exit 0; API `tsc --noEmit` exit 0;
83/83 CLI tests pass; 17/17 book tests pass; both new board JSONs valid; the
strategist org header intact; `analysis check` PASS/FAIL behavior reproduced live.

---

## 3. Prioritized REMAINING backlog (the deeper authoring/rendering)

### 3.1 — Stage-2 analysis QUALITY (the strategist's runtime job) · `[P1, runtime]`
The gate enforces the **floor** (grounded + present + substantive + covered), not
the **ceiling**. It cannot judge whether the voice insight is *insightful* vs
merely true, or whether copy-/ad-ideas genuinely extend what's converting. That
lives in the strategist's reasoning (Method + Quality-bar sections),
unenforceable deterministically.
**Next action:** run the `author-analysis` board task against a real harvested
brand; eval the emitted `analysis/*.org` for insight quality, not just gate-pass.

### 3.2 — Testimonial-quote byte-provenance · `[P2, gate]`
The gate confirms a testimonial cites a real social/catalog point; it does **not**
yet assert the quoted string appears in that point's source text.
**Next action:** add a `quote_grounding` check that fuzzy-matches `:QUOTE:`
substrings against the cited point's body to catch invented quotes (today caught
only by the "never fabricate" instruction).

### 3.3 — Data-driven slide composition (org → slide mapper) · `[P1, authoring]`
The deck is still a fixed template (`presentation-shell.ts` renders ~10 slides
from `composeBookData`/`CuratedBook`, not from the org substrate+analysis). The
bundling foundation is real and packages the full workspace; slide *generation
FROM* `analysis/*.org` `:insight:`/`:GROUNDS:` (voice/positioning/copy-ideas/
ad-ideas slides) is the remaining authoring layer.
**Next action:** build the `analysis/*.org` → slide mapper (one slide per
insight family) so deck content is data-driven, not templated.

### 3.4 — Query path proven end-to-end + board dynamism · `[P2]`
- **3.4.2** No published brandnana book has been `wb query`'d yet — the family-tag
  scheme (`:insight:voice:` etc.) in `query-book.org` is prescribed but unproven
  against a real produced book. **Next action:** after 3.1 authors a book, run
  `wb workbook query book.html "(and (tags insight) (title ~ voice))"` and confirm
  rows return.
- **3.4.3** Dynamic per-page board growth (PLAN §1b stages 2/4 — editor authors N
  page-tasks from data, second-pass balloon) is unbuilt at the runtime level;
  today's board is the fixed 3-stage spine.
- **3.4.4** `brandnana book list` discovery verb is assumed by `query-book.org`'s
  "find which book to query" flow; if absent, needs a real CLI verb or R2
  manifest.

### 3.5 — Per-event vendor-cost / margin ledger · `[P3, internal-only]`
`index.ts:97-105` calls `priceAndUpdateEvent(... [] ...)` so every `events` row
records `vendor_cost_usd=0`. Root cause: `vendor.ts:108-128` `logCall` has no cost
column, and no request-scoped collector threads vendor calls back to the
middleware. **Customer-facing `brandnana usage` is NOT broken** —
`usage.get` (`usage/routes.ts:43-108`) rolls up the `vendor_calls` table with a
`COST_PER_1K_CALLS` estimate. Only the internal per-event margin ledger is empty.
**Next action:** add provider→rate-card cost derivation + a request-scoped
collector plumbed through `VendorFetchOptions.ctx`.

### 3.6 — Private `.html` serve key mismatch · `[P3, pre-existing]`
`serve.ts:65` reads `brand-books/private/<user.id>/<slug>.html` but `POST /v1/book`
writes only `brand-books/<account_id>/<slug>/latest.tar.gz`. The private single-
file `.html` route has no producer.
**Next action:** decide — either have `routes.ts` also `put` the per-account
`.html`, or drop the private `.html` route in favor of tar.gz download.

### 3.7 — Other recorded-for-design deferrals · `[P3]`
- **Dead OAuth modules** `oauth/tiktok.ts`/`oauth/google.ts` (`export {}`, never
  mounted) — vestigial "bring-your-own-ad-account" scaffolds; all TikTok/Google
  data flows through ScrapeCreators (no user OAuth). Real OAuth design work or
  delete.
- **`design.tokens` v2 enrichment** (`design/routes.ts:15-24`) — corner radii /
  spacing / CSS custom props deferred to a Browser Rendering computed-style pass
  (v1 covers the 80% case).
- **No WASM/Theater runtime in the book shell** (`book-bundle.ts:32-33`,
  wb-0wst.6) — in-book live OQL (vs unbundle-then-query) awaits the oql-wasm
  embed; out of scope for Worker bundle size today.
- **`analysis build` scaffolder does not exist** — Stage-2 is intentionally
  LLM-authored (the reasoning IS the value); only `analysis check` is
  deterministic. `registerAnalysisCheck` reuses an existing `analysis` group if a
  future `build` lands.

---

## 4. Single end-to-end acceptance test (the whole product)

This is the one test that proves the product works front-to-back. Each step has a
deterministic pass condition; steps 2 and 3 are the gates the board already
enforces.

```sh
# 0. Pick a real mid-tier DTC brand (e.g. Caraway, True Classic, Tecovas).
BRAND="caraway"
WD="$(mktemp -d)"; cd "$WD"

# 1. HARVEST → deterministic substrate (Stage-1, already DONE).
brandnana substrate build  --brand "$BRAND" .
brandnana substrate check  .            # MUST exit 0 (5/5 OQL validation)

# 2. ANALYSIS GATE (Stage-2). Strategist authors analysis/*.org, then:
brandnana analysis check .              # MUST exit 0
#   → every :insight: has :GROUNDS:; every citation resolves to a real Stage-1
#     :point:; 7 core types covered; bodies substantive. Fails LOUD (exit 1)
#     on any ungrounded/dangling/skeleton insight. (PROVEN this push.)

# 3. DECK BUNDLE + ROUND-TRIP (Stage-3). Compose deck → single-file book.html:
#   book.html embeds <script id="wb-source-bundle" ... data-version="1" ...>
rm -rf .wb-unbundle-check
wb unbundle book.html .wb-unbundle-check
test -f .wb-unbundle-check/brand.org             # substrate rode in
test -f .wb-unbundle-check/analysis/*.org 2>/dev/null || \
  ls .wb-unbundle-check/analysis/*.org           # analysis rode in too

# 4. PUBLISH → serve. POST writes brand-books/public/<slug>.html:
SLUG="$(brandnana book publish . | jq -r .slug)"
curl -fsS "https://api.brandnana.net/books/$SLUG.html" -o served.html
#   → 200, content-type text/html, renders in browser AND unbundles.

# 5. AGENT QUERIES the published book (book-as-backend):
wb workbook query served.html '(and (tags insight) (title ~ voice))'
#   → returns the voice analysis rows straight out of the published book,
#     each carrying its :GROUNDS: receipt. (Step 5 is WIRED-FOUNDATION:
#     proven via round-trip; awaits a real authored book to run for real.)
```

**Status of this test today:** Steps 0–1 and the **gate logic** of steps 2–4 are
DONE and proven (typecheck-clean, gates fail-loud-verified, bundle round-trips
against forge's own parsers, serve path confirmed). Steps 2-authoring, 3-compose,
and 5 require the **strategist agent to actually run** and emit grounded
`analysis/*.org` + a data-driven deck — that runtime authoring is the
WIRED-FOUNDATION work tracked in §3.1 and §3.3.

---

## Summary (12 lines)

1. The **brand-book layers on top of the proven Stage-1 substrate are now real and compile-clean** — nothing in the owned path is stubbed-but-pretending.
2. **Stage-2 gate `brandnana analysis check` is DONE**: created, wired (`index.ts:4,79`), and **fail-loud-proven** live — grounded → PASS exit 0, one dangling citation → FAIL exit 1 naming the ghost point.
3. The gate enforces grounded + present + substantive + 7-type coverage; **dangling citations are rejected** against anchors built from the real substrate.
4. **Stage-3 `data-version="1"` audit bug is FIXED** — centralized in `renderSourceBundleScript()` (`book-bundle.ts:54-65`), wired into all 3 shells; round-trips against forge's own parsers.
5. **Board seam is wired**: a runtime-enforced harvest→analysis→deck DAG with deterministic acceptance gates (`analysis check`, `wb unbundle` round-trip).
6. **Query path is wired**: canonical `wb workbook query` with OQL s-exprs per eval ask; `analysis/*.org` rides into the book and is queryable after unbundle.
7. **Publish/serve is DONE**: `POST /v1/book` → `brand-books/public/<slug>.html` → `GET /books/:filename` as `text/html` with `frame-ancestors *`.
8. **Verify is green**: CLI + API `tsc --noEmit` exit 0; 83/83 CLI tests, 17/17 book tests pass; both board JSONs valid; strategist header intact.
9. **Biggest remaining work is design-heavy and honest**: the strategist's analysis QUALITY (§3.1) and the org→slide composition mapper (§3.3) — both are the LLM's runtime authoring job, not stubs.
10. **Recorded deferrals** are correctly-scoped, not silent dead-ends: testimonial byte-provenance, dynamic board growth, internal per-event margin ledger, private `.html` serve key, dead OAuth modules, design.tokens v2, in-book WASM OQL.
11. The **single end-to-end acceptance test** (§4) is fully specified; its gate logic is proven today, its authoring steps await the strategist actually running.
12. **No git commit / deploy performed**, per instruction; all changes sit on `brandnana-remediation-p0`.
