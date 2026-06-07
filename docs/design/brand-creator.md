# The Brand Creator (DESIGN, 2026-06-05)

**Status: buildable design, first build target.** Realizes the CK3/heraldry logo composer
ruled in `DECISIONS.md` (2026-06-05 "Avatars locked…") and the logo kit specced in prose at
`dynamic-content.md §0.3`. Grounded in the shipped sim: `sim/namegen.lua` already generates the
brand *brain* (name + vertical + traits + palette_id + starting_product). The Brand Creator is the
**player-driven front-end of `Namegen.identity`** — same data record, player-chosen instead of
seeded — plus the one new thing the prose never built: the **baked logo atom tables and the
compositor**. That data + compositor is the whole build.

Companion docs: `dynamic-content.md` (the tiered-dynamism thesis + §0.3 kit spec),
`design/design-rules.md` (icon/color/type law — the hard constraints below cite it),
`brands-and-products.md` (brand-as-character; the Product Creator owns the tech tree + label decals),
`design/flows.md` (where this screen sits in the loop).

---

## 0. What already exists vs what this builds

| Concern | Already shipped | This doc builds |
|---|---|---|
| Brand name | `Namegen.brand(rng, vertical, traits)` — patterns over closed banks, blocklist-screened, CI-lintable | re-roll UX + record field; **custom typed name deferred** |
| Full seeded identity | `Namegen.identity(rng, vertical)` → `{name, pattern, vertical, traits(3/12), palette_id(1–8), starting_product}` | "Surprise me" = call it verbatim, then let the player nudge the same record |
| Verticals / traits | `Namegen.banks()` (skincare, cookware, software, apparel), `Namegen.TRAITS` (12), `Namegen.BLOCKLIST` | vertical picker + trait display; blocklist screen reused on any name shown |
| palette_id | an integer 1–8 returned by `identity`, **read by no sim math** (verified: only written by namegen, asserted by `test_namegen`) | the baked `PALETTES` table the integer indexes into, + the picker |
| Logo | **prose only** (`§0.3`) | `sim/logo.lua`: baked atom tables (containers / glyphs / palettes / fonts / layouts) + `validate` + `resolve` + a CI lint over the full reachable logo namespace |
| Rendering | Defold atlas-PNG + runtime-tint pipeline (design-rules §SVG→Defold); `main.font` SDF proven on-device | a `logo` GUI scene that consumes resolved draw-ops; new `logo.atlas` + `logo_marks.atlas` + wordmark fonts |
| Save identity | (none — owned by the menu/save designer) | defines the **identity record** that keys the save (name + logo recipe) |

**The load-bearing fact that keeps this safe:** in v1 a brand's `vertical`, `traits`, `palette_id`
and logo recipe are **identity/presentation only** — no economy or resonance code reads them
(`grep` confirms: `palette_id` has zero sim readers; the `traits` consumed by `strategist.lua`/
`bots.lua` are unrelated *hire* traits). So the Brand Creator **cannot break the determinism of the
429-test sim core or the published economy numbers.** It writes a record and seeds a run; it never
feeds the math. If a future ruling makes brand traits mechanical, that is a `resonance.lua`/
`economy.lua` change — *not* a Brand Creator change. Keeping this boundary is a design rule, not an
accident (see §8 Risks).

---

## 1. The data model — the brand identity record

The composed brand is a flat, data-only Lua table of integers and stable string IDs (the
`content.lua` data-only discipline: no functions, snake_case IDs, locale-ready). It is
**namegen-compatible**: every field that `Namegen.identity` returns is present and same-typed, so the
seeded path and the player path produce interchangeable records.

```lua
brand_identity = {
  schema   = 1,                 -- brand_identity_format; bump for migrations (save compat)
  source   = "player",          -- "player" | "seeded" — provenance, for replay/telemetry
  seed     = 4815162342,        -- the run seed this identity keys (and the save's run-key)

  -- naming brain (verbatim Namegen.identity shape) -------------------------
  name     = "Hearth & Hew",    -- the wordmark string; blocklist-screened
  pattern  = "amp",             -- which Namegen pattern produced/matches it (lint + flavor)
  vertical = "cookware",        -- one of Namegen.banks() keys
  traits   = { "heritage", "cozy", "earnest" },  -- 3 of Namegen.TRAITS (grammar + flavor)
  starting_product = "Skillet Dutch Oven No. 4", -- Namegen.product(); Product Creator may override

  -- logo recipe (the CK3 heraldry composition) — all atom IDs into sim/logo.lua tables
  logo = {
    container  = "crest",       -- CONTAINERS id  (~12 badge shapes)
    glyph      = "skillet",     -- GLYPHS id      (vertical-tagged motif mark)
    palette_id = 3,             -- 1..8 → PALETTES (== the namegen field; player sets it directly)
    font       = "fraunces",    -- FONTS id       (wordmark display face)
    layout     = "stack",       -- LAYOUTS id     (arrangement template)
  },
}
```

Notes that matter for the build:
- **`palette_id` IS the bridge.** Namegen rolls `1 + rng % 8`; the player picks one of 8 swatches.
  Same field, same range — a seeded record and a hand-built record validate identically.
- **No raw colors or pixel coords in the record.** Colors live in the baked `PALETTES` table;
  positions live in the baked `LAYOUTS` template. The record is *recipe*, not *render* — so it is
  tiny, diffable, deterministic, and re-skinnable when art is upgraded without migrating saves.
- **The record is the save's identity key.** Name + logo recipe = "the save's identity IS the brand
  you made" (`DECISIONS.md`). The menu/save designer owns *how* it's persisted; this doc owns *what
  the record is* and that it is the key.

---

## 2. The baked atom tables — `sim/logo.lua` (the new module)

A new pure-Lua sibling to `namegen.lua`, framework-free per the architecture rule ("the entire
simulation lives in plain framework-free Lua modules; Defold is only the presentation shell"). It is
**not tick code** — it's identity/presentation data + a resolver — but living in `sim/` makes the
whole logo namespace CI-lintable exactly like the name namespace is. Determinism discipline applies:
integer/string atoms, canonical-ordered iteration, no `pairs()` in `resolve`.

### 2.1 The five banks (the actual content deliverable)

```
CONTAINERS  ~12   badge shapes: circle, disc, crest, shield, lozenge, hexagon,
                  banner, ribbon, rounded_square, oval, seal, tab
                  → each one WHITE sprite in logo.atlas, runtime-tinted
GLYPHS      ~40   motif marks, vertical-tagged + a few "universal":
                  skincare: leaf, droplet, petal, sprig, sun, jar
                  cookware: skillet, flame, whisk, knife, pot, wheat
                  software: cursor, signal, bolt, hexchip, branch, terminal
                  apparel : needle, hanger, tee, sock, button, cuff
                  universal: star, diamond, monogram (brand initial), wave, dot-grid, crown
                  → each one WHITE sprite in logo_marks.atlas, runtime-tinted
PALETTES     8    indexed by palette_id; each = an ordered, curated swatch set with
                  fixed colour ROLES (see 2.2)
FONTS       ~4    wordmark display faces (see 2.3)
LAYOUTS     ~6    arrangement templates (relative node coords; see 2.4)
```

Reachable logo space (MVP cut, §6) ≈ `12 containers × 24 glyphs × 8 palettes × 3 fonts × 3 layouts`
= **~20,700 distinct, crisp, in-style, deterministic logos** — the §0.3 "tens of thousands" claim,
made a tested number by the CI lint (§5). Full §0.3 cut (40 glyphs, 6 layouts) ≈ 138k.

### 2.2 Palettes — and the color-law firewall

Each palette is a small ordered table with **named roles** so a layout can ask for "container fill",
"glyph ink", "wordmark ink" without knowing the hex:

```lua
PALETTES[3] = {
  id = 3, name = "hearthstone",
  bg    = 0x2C2A28,   -- container fill
  fg    = 0xE7C56B,   -- glyph
  ink   = 0x2C2A28,   -- wordmark
  accent= 0xB1502E,   -- optional second glyph color / underline
}
```

**The hard constraint (design-rules §4 "a color never moonlights"):** the brand palette is rendered
**only inside the logo / brand-art surface** — the logo preview card, the save tile, the client/
account header art well, the product label (Product Creator), ad-card art wells. It **never** touches
chrome: chips, buttons, meters, pips, the score plate, status colors. Green stays money, red stays
fatigue, blue stays agency — a brand whose palette is red/green does not leak those meanings onto the
UI, the same way emoji-placeholder art never shares a surface with Phosphor chrome icons. This is the
single most important rule for not corrupting the curriculum's color vocabulary.

Picking a palette **is** picking the "2-3 color scheme" from `DECISIONS.md` — the role mapping is
designer-curated per palette (guaranteed container/glyph contrast), so the player chooses a coherent
scheme, not three raw colors that might collide. Per-swatch role remapping is deferred (§7).

### 2.3 Wordmark fonts — which faces, and why they're art-side

The UI type system is **locked**: Baloo 2 (display/numbers/names) + Nunito (body/labels), no third
typeface. Wordmark fonts do not break that rule because they are **art-side, not chrome** — they
render only inside the logo composite, never as UI text (same exception class as logo marks and
emoji card-art). MVP set of 3 (expand to 4), all OFL/Apache, all Defold-SDF-friendly:

| `font` id | Face | License | Archetype / trait affinity |
|---|---|---|---|
| `baloo`   | Baloo 2 ExtraBold (**already in repo**, `main.font`) | OFL | rounded chunky — the friendly default; `playful`, `cozy` |
| `fraunces`| Fraunces 9pt Black | OFL | soft heritage serif — `heritage`, `premium`, `earnest` |
| `archivo` | Archivo Black / Expanded | OFL | bold grotesque — `clinical`, `bold`, `nerdy` (software) |

A 4th poster face (e.g. Lilita One, OFL) is the cheap expansion slot. The brand's `traits`/`vertical`
*suggest* a default font (e.g. heritage → `fraunces`) but the player always picks. Each face is one
Defold SDF font resource — keep to ~4 (atlas/binary cost is the reason for the cap, design-rules §3).

### 2.4 Layouts — the arrangement templates

Each layout is relative node geometry (anchor, x/y, scale, z) for three nodes — `container`, `glyph`,
`wordmark` — normalized to a unit box so the same recipe renders at any size (chip → header → splash):

```
stack       glyph in container, wordmark centered below      (the default badge)
inline      glyph in container at left, wordmark to the right (horizontal lockup)
monogram    container + brand initial as the glyph, no wordmark (compact / favicon use)
```

MVP ships 3 (`stack`, `inline`, `monogram`); the §0.3 target is ~6 (add: banner-with-name-inside,
crest-over-name, glyph-only seal). Layout drives which nodes draw — `monogram` suppresses the
wordmark node, so the same `resolve` handles every layout.

### 2.5 The resolver — `Logo.resolve(recipe) → draw_ops`

Pure function: takes a `brand_identity.logo` recipe, reads the baked tables, returns an **ordered list
of draw-ops** the Defold GUI replays. No generation, no float drift, no `pairs()`:

```lua
-- returns, in z-order:
-- { kind="sprite", atlas="logo",       image="crest",   tint=PALETTES[3].bg,  x,y,scale, z=0 }
-- { kind="sprite", atlas="logo_marks", image="skillet", tint=PALETTES[3].fg,  x,y,scale, z=1 }
-- { kind="text",   font="fraunces",    text="Hearth & Hew", color=PALETTES[3].ink, x,y, z=2 }
```

Containers and glyphs are authored **white** and tinted by GUI node color (one texture per shape
serves every palette — design-rules §3: "recoloring a state costs zero new assets"). The wordmark is
a Defold text node in the chosen SDF font. `Logo.resolve` is the only seam between the data record and
the screen — the same function renders the live preview, the save tile, and every in-game brand
surface, so they can never disagree.

### 2.6 `Logo.validate(recipe) → ok, errors`

Boot/CI tool (like `Content.validate`): asserts every atom id resolves; `palette_id ∈ [1,8]`; the
`glyph` is tagged for the recipe's `vertical` **or** is universal; the name passes the same
`Namegen.BLOCKLIST` screen; and a **min-contrast check** between container fill and glyph (and
wordmark ink and its backdrop) — the lint that prevents a muddy, unreadable badge (§8). A tiny
`COMBO_BLOCKLIST` (mirroring `Namegen.BLOCKLIST`) can forbid specific ugly container×glyph pairs if
curation finds any.

---

## 3. The screen flow

Landscape, built **only from `design-language.html` components** (design-rules method ruling: screens
are assembled from the library, never invented). Cards are the UI; state is treatment; one thing
animates at a time; the confirm is the blue agency button.

### 3.1 Where it sits in the loop

```
TITLE ──[New Game]──▶ ★ BRAND CREATOR ──[Start]──▶ CLIENT SIGNING ──▶ WEEK 1 BRIEF ──▶ THE DESK
        [Continue]──▶ (load existing save → THE DESK)
```

The Brand Creator runs once, at New Game, **before** the run begins. Its output writes the new save
(name + logo = the save's identity key) and supplies the run seed + `vertical`/`traits` that downstream
namegen calls (product names, ad flavor lines) read. (Whether the brand is "you" vs a client-character
is the open identity ruling in `brands-and-products.md §3` — out of scope here; the Brand Creator only
produces the identity record + seed, and is agnostic to that fiction.)

### 3.2 The single screen

One screen, two zones (landscape):

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  NEW BRAND                                              [ Surprise me 🎲 ]     │
│ ┌───────────────────────────┐   ┌───────────────────────────────────────────┐│
│ │   LIVE LOGO PREVIEW        │   │ VERTICAL  ◉skincare ○cookware ○software ○app││
│ │   (the composite card,     │   │ NAME      “Hearth & Hew”      [ re-roll ↻ ]││
│ │    rest-shadow, big)       │   │ MARK      [▢leaf][▢pot][▢whisk][▢flame] …  ││  ← glyph tray (mini-cards)
│ │                            │   │ BADGE     [○][◇][shield][banner][seal] …  ││  ← container tray
│ │   ⌂ Hearth & Hew           │   │ COLORS    [▦][▦][▦][▦][▦][▦][▦][▦]         ││  ← 8 palette swatches
│ │                            │   │ WORDMARK  [Baloo][Fraunces][Archivo]       ││  ← font tray (name set in each)
│ └───────────────────────────┘   │                                  [ START ] ││  ← blue agency button
│                                  └───────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

- **Live preview** is the `Logo.resolve` composite rendered into a component card (rest shadow, chunky
  radius). Every pick re-composites instantly — pure sprite swap/tint, zero generation, zero latency.
- **Every tray item is a mini-card** (cards-are-the-UI). Selection = the seated/pressed treatment
  (snap, ≤120ms); no new chrome, no checkmark badge — the selected card sits pressed.
- **Vertical** is picked first; it filters the glyph tray to that vertical's marks (+ universals) and
  pre-fills a sensible name/palette/font suggestion. Changing it re-rolls the name and re-filters marks.
- **Name** shows the current `Namegen.brand` output with a **re-roll verb** (Phosphor `shuffle` Fill);
  each tap draws a new in-style, blocklist-safe name from the closed banks. (Custom typed name is
  deferred — §7.)
- **Surprise me** calls `Namegen.identity(seed, vertical)` verbatim and pre-fills *all* pickers from
  the resulting record — the seeded roguelike identity as a starting point the player then nudges.
  This is the literal proof that the seeded and player paths are one record.
- **Colors** = 8 palette swatch chips (each shows its 2-3 role colors). Tap sets `palette_id`.
- **Wordmark** = the brand name rendered in each candidate font; tap to choose `font`.
- **Layout** is not a top-level picker in MVP (default `stack`; `inline`/`monogram` chosen by render
  context). A layout toggle is the first easy expansion.
- **START** (blue, design-rules agency color — same class as End Day) runs `Logo.validate`, writes the
  `brand_identity` record + creates the save, and proceeds to Client Signing.

### 3.3 First-30-seconds feel

Title → New Game → the screen opens **pre-filled with a Surprise-me identity already composed** (no
blank state — the roguelike fantasy is visible immediately). The player re-rolls the name a couple of
times, swaps a mark, taps a warmer palette, picks a serif wordmark, hits START. Under a minute,
ceremony-light, and it produced a save whose identity is unmistakably *theirs*.

---

## 4. How it touches `sim/`

| `sim/` surface | How the Brand Creator uses it |
|---|---|
| `Namegen.banks()` | the 4 vertical chips + the glyph-tray vertical filter |
| `Namegen.brand(rng, vertical, traits)` | the re-rollable name (in-style, blocklist-safe) |
| `Namegen.identity(seed, vertical)` | "Surprise me" — pre-fills the whole record |
| `Namegen.TRAITS` | the 3 traits carried on the record (grammar + flavor; trait→font/palette default hints) |
| `Namegen.product(rng, vertical)` | `starting_product` on the record (handed to the Product Creator) |
| `Namegen.BLOCKLIST` / `blocked()` | screen on **every** name shown (re-rolls are pre-screened; custom entry, when added, must reuse this) |
| `sim/rng.lua` | substream the in-screen rolls: `Rng.substream(seed, "brand_creator")` so the screen is itself deterministic/replayable |
| **`sim/logo.lua` (new)** | `validate` on START, `resolve` for every render |
| `sim/content.lua` discipline | the record obeys the data-only / snake_case-id / locale-ready laws |

**What it deliberately does NOT touch:** `resonance.lua`, `economy.lua`, `wave.lua`, `fatigue.lua`.
Brand identity is flavor/presentation in v1; it must not feed the funnel math (preserves determinism +
the published numbers). The run seed it writes is what wires it to the wave machine — through
`Game.new(seed, pack)`, not through the brand fields.

---

## 5. CI lint — the namegen guarantee, extended to logos

The closed banks let CI enumerate the **entire reachable logo namespace** (what no generative model
can offer — `dynamic-content.md` thesis). Add `test/sim/test_logo.lua`:

1. **Every atom resolves** — iterate all `container × glyph × palette × font × layout`; assert
   `Logo.resolve` returns a complete, well-formed draw-op list for each (no nil atom).
2. **Count the namespace** — assert the distinct-logo count equals the expected product (the §2.1
   number becomes a regression-guarded fact, not a marketing claim).
3. **Contrast floor** — every (container, glyph) and (backdrop, wordmark) pair clears the min-contrast
   threshold, or is in `COMBO_BLOCKLIST`; no muddy/unreadable badge can ship.
4. **Name screen** — fuzz `Namegen.brand` across verticals/traits and assert zero blocklist hits
   (extends the existing name lint to the creator's surface).
5. **Seeded↔player parity** — a record from `Namegen.identity` validates byte-identically to one the
   creator could produce (the two paths are one schema).
6. **Determinism** — `resolve` uses canonical-ordered iteration, no `pairs()` (golden-lint clean).

---

## 6. MVP scope (the first build)

Ship the smallest cut that feels combinatorial and proves the data model end-to-end:

- **Data model:** the `brand_identity` record (schema = 1), locked.
- **`sim/logo.lua`:** baked tables — **12 containers, 24 glyphs (6/vertical + 6 universal), 8 palettes,
  3 fonts, 3 layouts** — + `validate` + `resolve` + `COMBO_BLOCKLIST`. (~20k reachable logos.)
- **`test/sim/test_logo.lua`:** the six CI assertions in §5.
- **The screen:** vertical · name(re-roll) · glyph · container · palette · font pickers + live preview
  + Surprise-me + START, assembled from existing design-language components.
- **Wiring:** namegen for name/traits/identity; write the save identity key (hand the persistence to
  the menu/save designer); supply seed + vertical/traits to the run.
- **Assets:** `logo.atlas` (12 white container shapes), `logo_marks.atlas` (24 white motif glyphs —
  **MVP source: a curated Phosphor Fill subset**, MIT, via the existing SVG→white-PNG rasterizer in a
  separate atlas/namespace), and 3 wordmark SDF fonts (Baloo 2 already present; +Fraunces, +Archivo).
- **Defold:** a `logo` GUI scene that replays `Logo.resolve` draw-ops; reusable at any size.

---

## 7. Explicitly deferred

- **Custom typed brand name.** MVP uses namegen re-rolls only — keeps every name in-style + blocklist-
  safe + within bounded length for SDF layout, and keeps the content **developer-authored, not UGC**
  (the App-Review/UGC posture that parked diffusion). Free-text entry needs a profanity filter, SDF
  glyph-coverage handling, length/overflow handling, and an ASO/trademark pass — a later feature.
- **Dedicated commissioned motif glyph set.** MVP reuses a Phosphor Fill subset (a logo mark that
  looks like a UI icon is the cost). Because glyphs are referenced by **stable string id** in a
  **separate atlas**, swapping in a bespoke set later is a pure asset change — no data-model migration.
- **Full §0.3 atom counts** (40 glyphs, 6 layouts, 4th font) — ship via Live Update data packs once the
  pipeline is proven; the lint scales automatically.
- **Per-swatch color-role editing / a 3-color custom mixer.** MVP: pick a curated palette = pick the
  scheme (guaranteed contrast). Free color mixing reintroduces the contrast/color-law risks the
  curated palettes exist to prevent.
- **Brand traits/palette as mechanical inputs** to resonance/economy. They are flavor-only in v1; making
  them mechanical is a `resonance.lua`/`economy.lua` change with its own tests and ruling — not part of
  this screen.
- **Mascot/person layer, product 3D-FBX label decal mapping, the product tech tree** — owned by the
  Product Creator (`brands-and-products.md`). The Brand Creator stops at the 2D identity record; it only
  hands `vertical`, `starting_product`, and the logo recipe (for the label decal) downstream.
- **Logo motion/foil treatment** — the composite is static in v1.
- **Editing the brand mid-run / rename + re-logo** — the logo is locked at creation to keep the save
  identity stable; a meta-level rebrand is a later feature.

---

## 8. Risks

- **Color-law collision.** A brand palette bleeding onto chrome would corrupt green=money / red=fatigue
  / blue=agency. *Mitigation:* the §2.2 firewall — brand palette renders only on the logo/brand-art
  surface, never chrome (same separation as emoji-vs-icon); enforce in code review + a render audit.
- **Logo illegibility at small sizes.** Some container×glyph×palette combos go muddy at chip/header
  scale. *Mitigation:* curated palettes with guaranteed role contrast; the §5 min-contrast lint;
  `monogram` layout for the smallest contexts; `COMBO_BLOCKLIST` escape hatch.
- **Phosphor-as-logo looks like UI.** Reusing the chrome icon source for brand marks risks
  no-distinctiveness. *Mitigation:* separate atlas + larger render + container framing in MVP; bespoke
  motif set is a non-breaking fast-follow thanks to id-stable references.
- **Seeded↔player drift.** "Surprise me" must yield a record identical to `Namegen.identity`, and edits
  must keep `palette_id ∈ [1,8]`. *Mitigation:* Surprise-me calls namegen verbatim; `validate` clamps/
  asserts ranges; the §5 parity test.
- **SDF text overflow.** Display fonts + longer names may overrun a layout. *Mitigation:* layouts
  size-fit/truncate; namegen names are bounded by the closed banks; cap wordmark length in `validate`.
- **Scope creep.** The screen wants to grow into product, mascot, identity-fiction territory. *Mitigation:*
  the §7 boundary — Brand Creator outputs an identity record + seed, nothing more.
- **Determinism regression.** A careless `resolve` (floats, `pairs()`) would violate the sim laws.
  *Mitigation:* `sim/logo.lua` is held to the same golden-lint as every sim module; `resolve` is
  integer/string + canonical-ordered.
</content>
</invoke>
