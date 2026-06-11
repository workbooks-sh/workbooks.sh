# Headline font pairs — trial log

The site's headline system is two slots, defined once in `:root` of
`web/index.html` and `web/learn/learn.css`:

- `--display` — the primary headline voice (shouting caps)
- `--accent` — the counterpoint inside headlines (`<em>` spans, capsule
  labels, kickers, TOC titles, FAQ `+`)

**Switching pairs = editing those two vars** (all trialed faces stay
registered as `@font-face`). One catch: the accent's `font-size` em-multiples
must be retuned per pair so BOTH FONTS HIT THE SAME CAP HEIGHT — measure with
`ctx.measureText("HE").actualBoundingBoxAscent` at 100px and set
`em = displayCaps / accentCaps`. Spots to retune: `article h2 em` +
`.lhero h1 em` (learn.css), `.lockup .jl:nth-child(2)` + `.sky-h em` +
`.s3-left h2 em` (index.html).

## Pairs tried (2026-06-11)

| # | display | accent | cap ratio (em) | verdict |
|---|---------|--------|----------------|---------|
| 0 | Anton (Google) | Handjet 900 (Google) | 1.16–1.24em | the original; pixel voice felt wrong → replaced |
| 1 | Anton | **IT Pixwix** | — | REJECTED — way too wide, "EMAILING" overflowed columns |
| 2 | Anton | **CS Golem** | ~1.0em | good fit, quirky rounded pixel; superseded by user's next picks |
| 3 | **Inkognito** (mono) | **CS Florens Pixel** (pixel serif italic) | .96em | strong techno/editorial mix; Florens has built-in slant |
| 4 | **Braked Bold** (condensed sans) | **Muzzaro** (condensed serif) | .67em | serif×sans editorial pair; superseded |
| 5 | **UM Warlock** (condensed display sans) | **Muzzaro** (condensed serif) | .70em | duo letters treatment; superseded |
| 6 | **Groothan Mixed** (one file, two styles) | — (same font) | 1em (same font) | CURRENT — see "Groothan case rules" below |

Notes:
- Braked's Bold cut is registered at `font-weight: 400` on purpose — display
  spots all say 400 and the face should land heavy like Anton did.
  (Semibold registered at 600 if a lighter display is wanted.)
- Muzzaro caps fill the full em (100/100px) — hence the small .67 ratio.
- Florens/Golem/Pixwix are pixel faces: keep `font-synthesis: none` so the
  browser never fake-bolds a bitmap grid.
- Body/mono stays JetBrains Mono; the dictionary defcards use EB Garamond.

## Groothan case rules (the current system)

Groothan Mixed packs the duo into ONE font: **UPPERCASE glyphs = bubble
display, lowercase glyphs = clean grotesque caps**. So the style mix is pure
CASE — no second family, no em-ratio. `text-transform: uppercase` was removed
from every headline; the authored case IS the design:

- Bubble appears in **headers/titles only** — never chips, kickers, TOC,
  body. (Chips/TOC keep Groothan but lowercase → grotesque.)
- **One-line title → exactly one bubble WORD** (`the DEFINITION`).
- **Multi-line title → single bubble LETTERS only** (`c<em>A</em>n't`).
- **Three-line lockup → the middle line is all-bubble**, white fill +
  thick ink outline (`-webkit-text-stroke` ~5-6.5px, `paint-order: stroke
  fill` — visible stroke is half the value), with condensed line-height and
  negative margins so it overlaps the grotesque lines on both sides
  (`.lhero h1 .bub`, and the landing hero's middle line).
- The landing hero's ASCII/scanline matte engine is RETIRED in favor of this
  bubble-outline system (matte functions remain in index.html, uninvoked).
