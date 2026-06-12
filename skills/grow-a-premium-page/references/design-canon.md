# The design canon — five axes, fixed as tokens

A **canon** is the small, fixed set of decisions every surface inherits. It is the
design analogue of the HOST layer: set once, changed deliberately, never
re-decided per section. A page that re-picks colors and fonts section-by-section
is the LOADED layer fragmenting because there is no canon above it.

The deliverable of Stage 0 is these five axes written as **tokens** (CSS custom
properties or an equivalent token file) — not prose, not a vibe.

## 1. Palette

- **One primary.** A single saturated brand color. Everything else is neutral or
  a tint of the primary.
- **Readable-on-X pairings — as a RULE.** State, explicitly, what the primary is
  paired with on light and on dark, because a saturated color is rarely readable
  on both. Pick the rule once (e.g. "primary on dark = bright; on light = a
  deepened variant; primary text always pairs with INK, never pure white").
- **Neutrals as a ramp**, not random grays — a named ink, a few surface steps, a
  hairline/border tone.
- **Name the collision to avoid.** The single rule that prevents drift, written as
  a sentence ("never introduce a second accent hue; blue is one tint, not a
  co-primary"). This is the most important line in the palette.

```css
:root {
  --primary: #..;       --primary-on-light: #..;   /* deepened for contrast */
  --ink: #..;           --surface-0: #..; --surface-1: #..; --hairline: #..;
  /* RULE: primary pairs with --ink, never pure white. No second accent hue. */
}
```

## 2. Type

- **Two faces, size-matched.** A title face (often a serif or a distinctive
  display) and a body/UI face (a clean grotesque). Match their visual size at a
  given px so they read as one system, not two pasted-together fonts.
- **A type scale**, not arbitrary sizes — a short ramp (e.g. 12 / 14 / 16 / 20 /
  28 / 40 / 64) referenced by token.
- **Mono is a spice, not a title font.** If a mono appears, scope it (code,
  eyebrows, labels) — don't set titles in mono.
- Fetch web fonts at build/runtime from a CDN with a content-addressed cache;
  don't pre-bundle whole OFL families.

## 3. Spacing & grid

- **An explicit spacing scale** (e.g. 4 / 8 / 12 / 16 / 24 / 40 / 64 / 96) — every
  gap and pad references it. No magic numbers.
- **One layout grid** (max content width, gutter, column count) that all
  archetypes lay out against.

## 4. Texture — the signature

The one non-flat element that makes the surface unmistakably *this* brand: an
ASCII/shader field, a grid texture, grain, a gradient wash. It is what separates a
premium page from a flat default.
- **Sparingly.** Texture is a seasoning behind content, not wallpaper on every
  block.
- **Tied to the palette** — the texture draws from the canon colors, it doesn't
  introduce new ones.

## 5. Voice

The copy register, captured so verbal and visual canon agree (confident vs.
playful, terse vs. expansive, and the words/claims the brand will and won't make).
A premium look with off-register copy reads as a template.

---

**Derive, don't invent.** If the brand has a site or an existing artifact, pull
the canon FROM it (palette via screenshot, fonts via the stylesheet, voice via the
copy) — the same discipline as building a brand book from a URL. Inventing a canon
from scratch is only for genuinely new brands, and even then anchor each axis to a
referent rather than guessing words/values in isolation.

**Gate:** you can paste the token block and state the ONE palette rule in a
sentence. If not, Stage 0 isn't done.
