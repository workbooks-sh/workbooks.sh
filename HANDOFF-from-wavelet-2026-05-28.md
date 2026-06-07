# Brandnana ↔ wavelet handoff — issues surfaced by v3h-gated postmortem

**Date:** 2026-05-28
**Source:** wavelet eval run `2026-05-28-nb-office-ugc-v3h-gated` (postmortem at `projects/wavelet/evals/runs/2026-05-28-nb-office-ugc-v3h-gated/postmortem.org`)
**To:** brandnana agent / API-side work
**Context:** This document collects every brandnana-side issue the wavelet
postmortem surfaced, so the brandnana agent can work them independently.
Each section is self-contained — no wavelet context required to act on it.

---

## TL;DR for the brandnana agent

The wavelet director loop consumes `brandnana book <domain>` as the
foundation of every ad it produces. The agent's downstream work
(strategy, screenplay, scene HTML, copy) takes its visual + brand
identity cues from the book payload. Right now the book is too thin to
support that — most fields come back empty for major brands, the logo
URL never validates, and there's no visual reference material in the
payload at all. The agent then reconstructs a generic brand treatment
from memory, and the resulting ads don't match what the brand's
website actually shows.

The three issues below are ranked by impact on perceived ad quality.
Each one is independent — fixing one would improve every wavelet run;
fixing all three would unblock the "ad brief = one-liner + URL"
discovery workflow we want next.

---

## How to reproduce + test (use this workdir)

The v3h-gated run captured every artifact needed to test brandnana
improvements end-to-end:

```
projects/wavelet/evals/runs/2026-05-28-nb-office-ugc-v3h-gated/workdir/brand/
├── SKILL.md                   — what the wavelet agent actually reads
└── newbalance.workbook.html   — the bundled brand book (.workbook.html)
```

The `SKILL.md` shows what brandnana book delivered against newbalance.com.
A fixed version should produce a SKILL.md with non-zero counts in every
section and a `## Visual reference` block (see issue 3 below).

To probe the live brandnana API after a fix:

```bash
brandnana book newbalance.com --force --out /tmp/nb-after-fix/
cat /tmp/nb-after-fix/SKILL.md
# Confirm:
#   - Catalog count > 0
#   - Competitors > 0  (when --competitors=… passed)
#   - Logo path validates (HTTP 200, > 1 KB, image content-type)
#   - extras.lifestyle_images[] present
#   - extras.homepage_screenshot present
#   - extras.style_signal present
```

When the testing agent serves the brand-book skill to validate this,
they should compare `SKILL.md` before/after on the same domain. The
existing `.workbook.html` from v3h-gated is a known-thin baseline.

---

## Issue 1 — `brandnana book` returns empty for major brands

**bd:** `wb-zghj` (closed and handed to brandnana agent 2026-05-28)
**Priority:** P1

### Evidence

Run against newbalance.com (a $4B brand with thousands of SKUs and
decades of ad creative). `SKILL.md` verbatim:

> Catalog: 0 products across 0 categories, 0 collections.
> Competitors: none captured.
> Ads: 0 captured from none.

API cost: $0.0040 — the verbs executed, they just returned empty
results. Provenance line says:
`Verbs run: brand.fetch, ads.search, catalog.crawl, design.palette`

So we paid for four verb invocations and got nothing usable back.

### Downstream effect

The wavelet agent, seeing an empty book, falls back to
"well-known brand identity" — i.e. reconstructing from training-data
memory. That reconstruction is *generic* (e.g. for NB: red CF0A2C +
Inter sans-serif), not what the actual website shows (NB's site is
monochromatic-heavy with serif + sans-serif paired). Every v3* ad that
chose a real brand has hit this fallback, and every result has been a
generic version of the brand rather than the website's actual treatment.

### Suggested fix path

When the primary vendor (Context.dev?) returns empty:

1. **Fall back to a secondary vendor** before declaring the book done:
   - Brandfetch /v2/brands/<domain>
   - logo.dev /v1/logo?domain=<domain>
   - A direct site crawl + vision-call summarization
2. **Hard-fail the `brandnana_research_done` gate** when the book has
   0 products AND 0 logo. Don't silently return success with empty
   content — force the agent to retry or use an alternate source.
3. **Improve the provenance line** to reflect actual outcomes per verb,
   not just the verbs that were invoked:
   ```
   Verbs run + outcomes:
     - brand.fetch: ✓ (palette + 2 fonts)
     - ads.search: ✗ vendor returned 0 ads (fell back to Firecrawl)
     - catalog.crawl: ✓ (47 products)
     - design.palette: ✓
   ```

### Test acceptance

`brandnana book newbalance.com --force` produces:
- `Catalog: ≥ 10 products` in `SKILL.md`
- Each product has at least a name + product URL + one image URL
- At least one valid `logo_url` (per issue 2 below)

---

## Issue 2 — Logo retrieval has failed in **every** v3* wavelet run

**bd:** `wb-i5je` (closed and handed to brandnana agent 2026-05-28)
**Priority:** P1

### Evidence

Across wavelet eval runs v3a → v3h-gated (eight runs, eight brands),
NO brand has ever produced a usable `logo_url` from `brandnana book`.
Every run, the wavelet agent falls back to rendering the brand name
in HTML text and noting the substitution in `brand.org`'s `:SOURCE:`
property.

The current flow appears to attempt a logo fetch, but the agent always
sees an empty / unreliable field. From `brand.org` in the v3h-gated
workdir, verbatim:

```
:LOGO_URL:   (none captured by brandnana book — using HTML text wordmark per brief)
```

### Downstream effect

A New Balance ad without the NB wordmark mark (the stylized "nb" inside
a parallelogram) doesn't read as a New Balance ad. The text "New
Balance" in any font is a logo *approximation*, not the logo. Every
wavelet ad currently ships with this approximation.

### Suggested fix path

Cascade through multiple sources, **first valid hit wins**:

1. Brandfetch `/v2/brands/<domain>?include=logos` — prefer SVG / type=icon
2. logo.dev `/v1/logo?domain=<domain>`
3. The site's `<link rel="icon">` / `<link rel="apple-touch-icon">`
4. The site's `<meta property="og:image">` (often the wordmark)
5. The first `<img>` whose `alt` attribute matches the brand name
6. A vision-call against the homepage screenshot: "Where is the logo in
   this page? Return the bounding box."

**Validate every candidate before accepting:**
- HTTP 200 (no 401, no 403, no redirect to login)
- `Content-Type` starts with `image/`
- Byte count > 1 KB
- For SVG: parse-able as SVG with at least one `<path>` / `<rect>` /
  `<polygon>` element
- For PNG/JPEG: parse-able header, dimensions > 100×100

If ALL sources fail: `brandnana_research_done` MUST fail with reason
`logo_missing`. Don't return success with an empty logo.

### Test acceptance

For at least 10 major brands (newbalance, nike, allbirds, hoka, asics,
on-running, brooks, saucony, mizuno, salomon), `brandnana book <domain>`
produces a `logo_url` that:
- HTTP 200s on direct fetch
- Is parseable as SVG or PNG/JPEG
- Visually matches the brand's published wordmark (eye-check)

---

## Issue 3 — Book payload lacks visual reference material

**bd:** `wb-fphf` (closed and handed to brandnana agent 2026-05-28)
**Priority:** P2

### Evidence

The current book payload (post-fix or otherwise) consists of:
- palette (hex codes, sometimes missing)
- font names (sometimes missing)
- voice/slogan text
- catalog (products, when issue 1 is fixed)

What's missing — and what wavelet needs to reverse-engineer brand vibe:

1. **Lifestyle imagery from product pages (PDPs).**
   Every PDP carries editorial / lifestyle / detail shots alongside the
   cutout product photo. These are how a human designer learns "this
   brand's vibe is monochromatic studio streetwear" or "this brand is
   sun-drenched outdoor lifestyle" — by SEEING the imagery, not by
   reading a `fonts:` string. wavelet's agent needs the same input.

2. **A full-page homepage screenshot.**
   The composition of a brand's homepage is brand signal. NB uses serif
   + sans-serif paired. Glossier uses massive product macro photography.
   Allbirds uses muted earth-tone color blocking. None of this is
   inferrable from a palette dump alone. The agent needs to SEE the
   landing page.

3. **An auto-derived style-signal line.**
   A one-line summary derived from a vision call on the homepage
   screenshot. Examples:
   - "Monochromatic studio composition with serif + sans-serif type pairing"
   - "Sun-drenched outdoor lifestyle, hand-held aesthetic, earthy palette"
   - "High-contrast hero typography over muted documentary photography"
   This becomes the agent's primary style cue when authoring the
   storyboard prompts.

### Proposed payload extension

```json
{
  "extras": {
    "lifestyle_images": [
      {
        "url": "https://cdn.newbalance.com/.../990v6-on-foot.jpg",
        "kind": "on_foot",
        "context_pdp_url": "https://newbalance.com/pd/.../M990GL6",
        "vision_alt": "Grey 990v6 on wood floor, hand reaching for it"
      },
      ...
    ],
    "homepage_screenshot": {
      "url": "https://cdn.brandnana.../newbalance-home-1280.png",
      "captured_at": "2026-05-28T21:57:10Z",
      "viewport": "1280×3200"
    },
    "style_signal": "Monochromatic studio with serif + sans-serif type pairing; flat color blocking; understated brand mark",
    "pdp_grid_per_top_sku": [
      {
        "sku": "M990GL6",
        "grid_url": "https://cdn.brandnana.../grid-M990GL6.png",
        "cells": ["cutout", "on_foot", "detail", "scale"]
      }
    ]
  }
}
```

`SKILL.md` should also surface a `## Visual reference` block:

```markdown
## Visual reference

The brand-book bundle includes:
- 12 lifestyle images across the top 5 SKUs (`extras/lifestyle/`)
- A homepage screenshot (`extras/homepage.png`)
- A 4-cell PDP grid per top SKU (`extras/pdp-grids/`)

Style signal (auto-derived):
> Monochromatic studio with serif + sans-serif type pairing; flat color
> blocking; understated brand mark.
```

### Cost estimate

Roughly $0.005-0.02 per book on top of current pricing:
- One vision call on the homepage screenshot for style_signal: ~$0.002
- ~10 PDP image fetches: free (just bandwidth)
- One headless-Chromium homepage capture: ~$0.001 (browser-rendering binding)
- Optional: one vision call per PDP image for `vision_alt`: ~$0.005

Trivial against the value to downstream agents.

### Test acceptance

`brandnana book newbalance.com` produces a SKILL.md that includes a
`## Visual reference` block AND the workbook.html bundles:
- ≥ 5 lifestyle images
- 1 homepage screenshot
- 1 non-empty `style_signal` string

---

## How wavelet consumes the book (so the brandnana agent has full context)

The wavelet director loop reads the brand book in 3 places:

1. **`brand-research.org` skill** — instructs the agent to run
   `brandnana book <domain> --competitors=<csv>` and write a `brand.org`
   summary. The skill's logo-retrieval section currently says:
   > The =logo_url= the book returned must download (HTTP 200, > 1 KB).
   > If it doesn't, escalate: =brandnana book <domain> --force= or query
   > the installed book for a different logo source. Every real brand
   > has a real logo somewhere. If you can't find it, write that down
   > in =notes.md= and stop — don't render the brand name as fallback
   > type.

   In practice the agent never finds a working logo, falls back to HTML
   text, and notes the substitution. Issue 2 unblocks this path.

2. **`scene-html-brand-contract.org` skill** — instructs the agent to
   author per-scene HTML using brand vars (display font, body font,
   primary / secondary / accent / product colors, logo URL). Right now
   the agent fills these from brand.org's reconstruction. With richer
   payload, the agent could fill them from real data.

3. **`strategy.org` PROMISE pillar** — derived from the brand voice +
   positioning the book surfaces. Currently uses heritage taglines from
   memory; would use real campaign copy if the book surfaced recent ads.

The wavelet-side test for any brandnana change: re-run v3h-gated against
the same brief but with the fixed brandnana CLI on PATH, and compare
the resulting brand.org, scene HTML overlays, and final MP4 for:
- Real logo present (SVG or PNG, on screen)
- Fonts matching the homepage screenshot
- At least one product-subject shot citing a real PDP lifestyle image

---

## Related wavelet-side issues (NOT for the brandnana agent)

These stay with the wavelet director rewrite epic `wb-raqt.12`:
- `wb-raqt.12.34` — verify-clip Google-direct gemini-3.5-flash validation
- `wb-raqt.12.35` — storyboard plan: require product-subject shots
- `wb-raqt.12.36` — scene-html: reduce sizes, modernize animations
- `wb-raqt.12.37` — transitions: ban fade/wipe/crossfade
- `wb-raqt.12.38` — scene-html: require original-written hero line
- `wb-raqt.12.39` — wavelet velocity outputs 156.4s for 25s brief

Top-level wavelet-adjacent:
- `wb-ey4c` — storyboard animate retry wastes Higgsfield credits on 5xx
- `wb-xapt` — skills: `pgrep -f` self-match deadlock pattern
- `wb-8bth` — minimal eval brief (one-liner + URL); retire NB brief

These three (1, 2, 3 above) are the **only** issues for the brandnana
agent. Everything else stays on the wavelet side.
