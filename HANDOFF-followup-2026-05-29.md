# Brandnana ↔ wavelet handoff — follow-up after patches landed

**Date:** 2026-05-29
**Tests run by:** wavelet side, live API
**Authoritative input:** `projects/brandnana/HANDOFF-from-wavelet-2026-05-28.md`
**CLI tested:** `projects/brandnana/apps/cli/dist/brandnana-darwin-arm64` (v0.1.0)
**Auth:** new API key (`adk_live_…`) authenticates as user `a6c7f45e-…` on tenant
distinct from the previous `e491b6c6-…` (good — the patches include account/auth changes).

## TL;DR

The **individual sub-verbs got real fixes** under the latest patches: `brandnana logo`
returns candidate URLs that actually download, `brandnana design tokens` returns the
real brand palette + fonts, `brandnana resolve` is working, cost telemetry is now
emitted to stderr. The **`book` orchestration step isn't yet pulling those outputs
into the bundle** — the generated `<slug>.html` + `SKILL.md` still report `Catalog: 0
/ Ads: 0` and ship a generic placeholder palette. Next patch should have `book`
internally compose `logo` + `design tokens` + (when wired) `catalog crawl` and `ads
search` results into the HTML bundle and SKILL.md.

When that composition lands, the bundle's data quality should immediately jump
because the upstream data is already there.

---

## Issue 1 — `brandnana book` returns empty for major brands

**Status:** ❌ Still failing at the `book` level. Sub-verbs are fixed; orchestration
isn't composing them.

### What the SKILL.md still says verbatim (4 brands tested)

```
Catalog: 0 products across 0 categories, 0 collections.
Competitors: <only when --competitors= passed>
Ads: 0 captured from none.
Media: static images embedded.   (or "video + static (R2-linked)" with --with-video)
```

Tested against `newbalance.com`, `allbirds.com`, `glossier.com`, `hoka.com`, `nike.com`
— all 4 return the same `Catalog: 0 / Ads: 0` pattern.

### What changed for the better

- **`--competitors=nike.com,asics.com`** now round-trips into SKILL.md as
  `Competitors: nike, asics` (was `none captured`). So the flag is wired through to
  the server.
- **`--with-video`** flips `Media: static images embedded` to `Media: video + static
  (R2-linked)`. So the video-capture flag is also wired through.
- The bundled file is now `<slug>.html` (no double-extension `.workbook.html` on disk
  — though the CLI's success-message text still echoes the old name). Matches the
  user's earlier "Brand-book file name is slug.html" rule.

### What the bundled `.html` actually contains (newbalance probe)

Inspected the embedded resources after running `book newbalance.com --competitors=…
--with-video --force`:

```
palette in html: #f0d060, #f4f4f4, #fffbea
fonts in html:   sans-serif
embedded logos:  0
data:image refs: 0
```

`#f0d060` is a yellow placeholder — not New Balance brand-canonical anything. The
real palette is below.

### What `brandnana design tokens newbalance.com` returns (the data `book` should be ingesting)

```json
{
  "domain": "newbalance.com",
  "fetched_at": 1780025737,
  "palette": {
    "primary":   "#d31e3d",            // ← canonical NB red
    "secondary": "#d88a9c",
    "all": ["#d31e3d", "#d88a9c"]
  },
  "fonts": [
    {
      "family": "Proxima Nova W01",
      "fallbacks": ["-apple-system", "BlinkMacSystemFont", "Helvetica Neue", …],
      "dominance": 0.98,
      "uses": ["body", "div", "header", "button", …]
    }
  ]
}
```

This is exactly the data the bundle should carry. The patch landed in `design
tokens` but didn't flow into `book`'s composition step.

### Suggested next step

`book`'s composition should call `design tokens` internally and embed the result
into the bundle's SKILL.md + `.html`. The same applies to `logo` (see Issue 2),
`catalog crawl` (the verb exists; need to confirm it's invoked), and `ads search`
(currently blocked on vendor wiring, but the dependency is internal-only).

---

## Issue 2 — Logo retrieval

**Status:** ✅ **Largely fixed at the verb level.** ❌ Still not embedded into the
`book` bundle.

### Per-brand verb output

| Brand | URL returned | Confidence | Source | Actually fetches? |
|---|---|---|---|---|
| `newbalance.com` | `simpleicons.org/icons/newbalance.svg` | 0.35 (last-resort) | simpleicons.org | ✓ HTTP 200, 844 bytes, valid `image/svg+xml`, contains the New Balance wordmark in path data |
| `allbirds.com` | Wikipedia Commons SVG | 0.60 (recommended) | `Wikipedia Commons (File:Allbirds logo.svg)` | (not fetched in test, but format matches) |
| `glossier.com` | `glossier-prod.imgix.net/files/Cropped_logo_white.png` | 0.60 (recommended) | `homepage <img> (alt="")` | (not fetched in test) |
| `hoka.com` | — (empty candidates list) | — | — | — |

3 of 4 brands get a usable logo URL. 2 of 4 clear the 0.50 confidence threshold.

### Gaps still open

- **`hoka.com` returns zero candidates.** The cascade isn't covering every brand.
- **No hard-fail enforcement.** When all sources fail (hoka case), the CLI returns
  an empty candidates list with no error. The handoff doc's suggested fix was
  `brandnana_research_done` should hard-fail when no logo lands; right now the
  caller has to detect the empty list themselves.
- **The bundle from `book` contains 0 logos / 0 data:image refs.** Even when
  `logo` would return a usable candidate, `book` isn't ingesting it.

### Suggested next step

When `logo`'s top candidate has confidence ≥ some threshold, `book` should
download the bytes and embed as `data:image/...;base64,...` in the bundle (so the
HTML works fully offline) AND surface the URL in SKILL.md (so wavelet's scene HTML
contract can use it as `--brand-logo-url`).

For brands where no source returns a candidate (hoka case), add at least:
- Try the site's `<link rel="apple-touch-icon">` and `<link rel="icon">` as a
  fallback (often 180×180 or 512×512 PNG; usable as a wordmark stand-in).
- Try `<meta property="og:image">` (often the brand's hero / banner image).

---

## Issue 3 — Lifestyle imagery, homepage screenshot, style signal

**Status:** ❌ Zero progress visible from the bundle inspection.

The book bundle for newbalance.com contains exactly 2 files:

```
newbalance.html
SKILL.md
```

No `extras/lifestyle/`, no `extras/homepage.png`, no `style_signal` field in
SKILL.md. None of the Issue 3 deliverables are present in the output.

This was the lowest-priority item on the original handoff (P2 vs P1 for the other
two) — flagging that it's still untouched but the order is fine.

---

## Side-channel findings (not in the original handoff)

These came up during the verb sweep:

### `brandnana brand fetch <domain>` — client-side SQLite error

```
brandnana brand fetch newbalance.com
→ brandnana: unable to open database file
```

The verb requires a workspace init (`brandnana init` to create `.brandnana/`).
Same as `ads search`. **Not a server bug** — but the error message should hint at
the missing init rather than just surfacing the raw SQLite error. The wavelet
agent saw this and (correctly) ignored the verb in v3h-gated.

### `brandnana social <platform> <handle>` — vendor not configured

```
brandnana social instagram profile newbalance
→ Brandnana API 503 Service Unavailable (/social/instagram/newbalance)
  body: {"error":"not_configured","message":"social-data backend not configured"}
```

The vendor backend (Apify / Phyllo / SocialCount / etc.) isn't wired server-side
on this account. The CLI surface for social lookups (`brandnana social {instagram,
tiktok, youtube, twitter, facebook, linkedin, reddit}`) is present, the routing
just dead-ends at "not_configured". Mentioning this here because it's relevant to
Issue 3 — once `social` works, the `style_signal` derivation could include the
brand's social presence as a signal.

### `brandnana ads search <query>` — same SQLite + server vendor gap

```
brandnana ads search "nike running shoes"
→ {"error": true, "name": "SQLiteError", "message": "unable to open database file"}
```

Client-side SQLite — needs `brandnana init` to land first. Once that's resolved,
the underlying ads vendor would also need to be wired (similar to the social case).

### `brandnana resolve <query>` — works, with cost telemetry

```
brandnana resolve nike
→ resolves to nike.com at 45% via Wikipedia infobox + direct fetch
  [brandnana-cost] usd=0.000000 ... capability=resolve sources=fetch:direct,wiki
```

Cost telemetry is now in the stderr — that's a new feature since the handoff was
written. Worth noting for the brandnana team: the wavelet trace shim picks this
up automatically if it appears on stderr.

---

## Acceptance criteria progress

From the original handoff:

| Acceptance criterion | Status |
|---|---|
| Catalog count > 0 | ❌ Still 0 across all brands tested |
| Competitors captured (when `--competitors=` passed) | ⚠️  Names round-trip into SKILL.md but no captured ad content |
| Logo path validates (HTTP 200, > 1 KB, image content-type) | ✅ Verified for newbalance (sub-verb level) |
| `extras.lifestyle_images[]` present | ❌ Not present |
| `extras.homepage_screenshot` present | ❌ Not present |
| `extras.style_signal` present | ❌ Not present |

---

## Recommended priority for the next patch

1. **Make `book` compose `design tokens` + `logo` into the bundle.** This is the
   single highest-leverage change — the data is already produced upstream; the
   bundle just isn't ingesting it. Both palette/fonts and logo are unlocked the
   moment composition lands.

2. **Hook `catalog crawl` into `book`** (the verb already exists). Even partial
   catalog data (top 10-20 SKUs) would jump SKILL.md's `Catalog: 0` to a useful
   number.

3. **Better error message for the workspace-init dependency** (currently `unable
   to open database file` for `brand fetch` and `ads search`). The agent reading
   that error message has no idea it needs to run `brandnana init`.

4. (Lower priority — server-vendor work) Wire the `social` and `ads` vendor
   backends so those don't 503 with `not_configured`. Once these work, Issue 3
   (style_signal derivation from social presence) becomes tractable.

5. **Hard-fail `brandnana_research_done` when no logo lands** (the hoka.com case).
   Right now an empty candidates list is silently OK; the gate should treat it as
   a failure so the downstream wavelet agent retries instead of falling back to
   HTML-text wordmarks.

---

## How to reproduce

```bash
# Set the new key
export BRANDNANA_API_KEY=adk_live_…

# Verify auth
brandnana whoami

# Run the failing case
brandnana book newbalance.com --force --competitors=nike.com,asics.com --with-video \
  --out /tmp/nb-test/

# Inspect what landed
cat /tmp/nb-test/SKILL.md             # Catalog/Ads/Competitors counts
ls /tmp/nb-test/                       # bundle file list
grep -oE '#[0-9a-fA-F]{6}' /tmp/nb-test/newbalance.html | sort -u
grep -oE 'Proxima|Inter|Helvetica' /tmp/nb-test/newbalance.html

# Compare to what the sub-verbs return
brandnana design tokens newbalance.com --json
brandnana logo newbalance.com --json
```

If a future patch lands and you want to re-snapshot: just re-run those commands
and update this doc with the new findings.
