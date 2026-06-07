# The Product Creator (DESIGN, 2026-06-05)

**Status: buildable design, grounded in shipped `sim/` primitives.** Realizes the DECISIONS
2026-06-05 ruling: *pick a category + a starting product; the brand's logo + label maps onto a
3D product FBX; add more products over time (the tech tree from `brands-and-products.md §2`),
broaden-never-strengthen.* Companion to the Brand Creator (build-first; produces the **logo
recipe** this system decals onto products) and the Ad Composer (consumes the **product art
layer** this system bakes).

---

## 0. TL;DR — what a product *is* in this game

A product is **not** a new card kind and **not** a hand card you compose. The grammar
(`[Hook][Visual][Format][Offer]+≤3 mods`) is untouched. A product is a small **DATA record**
that does exactly three things, each wired to an existing sim system:

| A product sets… | …which touches | …concretely |
|---|---|---|
| **The economy base** (AOV + CVR) | `economy`/`funnel` via `Game.compose` | the run's active product replaces the global `BASE_TRUTH.aov_cents` / `cvr_ppm` reads |
| **The offer space** (which Offer cards exist) | `content` (kind `offer`, `EFFECTS`) | a product unlocks a list of already-authored offer-card ids into your collection |
| **The product art layer** | the layered art system / Ad Composer | a baked toon FBX sprite + a runtime brand-logo decal = the `[PRODUCT]` layer |

So: **the product is the run's economic substrate + an art layer; the "playable card" a
product yields is its Offer card(s).** The tech tree broadens all three — never strengthens
them (§7). This is the same conservation discipline as the V2-foil mint (`economy.lua:138`):
a new product *moves you to a different point on the AOV×CVR frontier*, it does not push the
frontier outward.

---

## 1. Where it sits in the flow

```
BRAND CREATOR  ──(logo recipe: container/glyph/colors/wordmark font)──┐
                                                                      ▼
PRODUCT CREATOR  →  pick category → pick form/type → pick STARTING PRODUCT
   (at brand creation)        │                                       │
                              ▼                                       ▼
                     run.products.roster = { starter }      product art = toon FBX
                     run.products.active  = starter           + brand-logo decal
                              │                                       │
   ┌──────────────────────────┴───────────────────────────┐         ▼
   ▼                                                        ▼   used by AD COMPOSER
ECONOMY BASE (aov/cvr)                          OFFER CARDS unlocked   as [PRODUCT] layer
into Game.compose                               into collection
                              │
                     mid-run: PRODUCT LAB (tech tree) → Develop new product → broaden
```

The Product Creator is the **second screen of brand creation** (right after the Brand Creator),
and re-opens mid-run as the **Product Lab** (the tech tree). It depends on the Brand Creator's
output (the logo recipe) for the decal, and feeds the Ad Composer (the product layer) and the
sim (AOV/CVR + offers).

---

## 2. The taxonomy: vertical → category → form-factor → product node

Four levels, all **data**, all extensible by adding a content pack (no code change):

```
VERTICAL        the brand's industry (from Brand Creator; drives namegen banks)
  └ CATEGORY    a product family within the vertical  (the player's first pick)
      └ FORM    the physical form-factor → ONE FBX + one label anchor  (asset reuse key)
          └ PRODUCT NODE   a concrete tech-tree node (Cleanser, Serum, SPF…)
```

**Form-factor is the asset-economy key.** Many products share one FBX, distinguished only by
brand-logo decal + palette tint + generated name — the Tier-0 combinatorial trick
(`dynamic-content.md §0.3/§0.4`) applied to products. A serum and an oil are both
`pump_bottle`; a cream and a balm are both `jar`. A handful of FBX → hundreds of distinct
product cards.

### v1 verticals (namegen banks already exist — `namegen.lua:11-44`)

Product nouns below map 1:1 to each vertical's `bank.product` list so the generated name
(`namegen.product`, §4c) stays in-grammar.

```
SKINCARE   forms: pump_bottle, jar, spray_bottle
  Cleanser*(jar) ─→ Serum(pump) ─→ SPF Cream(jar) ─→ {Bundle, Subscription}
                 └─→ Face Oil(pump)   └─→ Mist(spray)
  shape: low AOV / high CVR  →  mid AOV / mid CVR  (impulse → considered)

COOKWARE   forms: pan, pot, blade
  Skillet*(pan) ─→ Dutch Oven(pot) ─→ {5-pc Set bundle}
               └─→ Chef Knife(blade)
  shape: HIGH AOV / LOW CVR throughout (durable, considered purchase)

SOFTWARE   forms: device_tile  (no physical product — a flat app/device card)
  Starter Plan*(tile) ─→ Pro Plan(tile, subscription) ─→ Team Plan/Suite(tile)
  shape: subscription-heavy → aov_plus_subscription offers dominate

APPAREL    forms: garment_flat, hanging_garment, accessory
  Tee*(flat) ─→ Henley(flat) ─→ Jacket(hanging) ─→ {Capsule bundle}
            └─→ Cap(accessory)
  shape: mid AOV, very bundle-friendly
```
`*` = starter (tier 0, no prerequisites).

### Next pack (DECISIONS examples — needs namegen banks added, §4c)

```
BEVERAGES  category: non-alcoholic | alcoholic ;  forms: can, glass_bottle, pouch
  non-alc:  Sparkling Water*(can) ─→ Functional Soda(can) ─→ {Variety Pack}
  alcoholic: Hard Seltzer*(can) ─→ Craft Lager(glass_bottle) ─→ {Mixed Pack}
  shape: very low AOV / very high CVR (impulse), extremely bundle-friendly

MAKEUP     category: cream | lip ;  forms: tube, compact, pump
  Tinted Balm*(tube) ─→ Palette(compact) ─→ {Beauty Kit box}
  cream:  Day Cream*(jar) ─→ Foundation(pump) ─→ {Kit}
```

The category pick (DECISIONS: "beverages → alcoholic/non; makeup → cream/lip-balm") is the
**first choice in the creator**, and it prunes the tech tree to one branch — a real
positioning decision, not cosmetic.

---

## 3. The product DATA record

Products are **content** — they live in the content pack and ride `content.lua`'s loader
sandbox, data-only scan, id discipline, retired-id law, and locale string layer for free.
Two new top-level content sections: `form_factors` (asset binding) and `products` (the tree).

### 3a. Form-factor record (`content.form_factors[]`)

```lua
{
  id = "pump_bottle",                 -- snake_case, content-legal
  fbx = "prod_pump_bottle",           -- author-time FBX asset id (tools/assets/)
  label_anchor = { 132, 210, 308, 470 }, -- baked screen-space rect {x0,y0,x1,y1} of the LABEL UV
                                         -- (emitted by blender_toon_card.py PRODUCT mode, §7)
  framing = "object",                 -- toon-render framing profile (centered object-fit, §7)
  strings = { en = { name = "Pump Bottle" } },
}
```

### 3b. Product record (`content.products[]`)

```lua
{
  id = "skincare_serum",              -- snake_case, NEVER reused (retired_ids enforced)
  vertical = "skincare",
  category = "treatment",             -- the player's first-pick family
  form = "pump_bottle",               -- → FBX + label anchor (3a)
  tier = 1,                           -- tech-tree depth; 0 = starter
  requires = { "skincare_cleanser" }, -- prerequisite product ids ({} for starters)
  product_noun = "Serum",             -- MUST equal an entry in namegen bank.product (§4c)

  -- ECONOMY CHARACTER — the product's point on the AOV×CVR frontier (§6 invariant):
  aov_cents = 5500,                   -- base order value (replaces BASE_TRUTH.aov_cents)
  cvr_ppm   = 16000,                  -- base conversion rate (replaces BASE_TRUTH.cvr_ppm)

  -- OFFER SPACE — offer-card ids this product unlocks into the collection (§5):
  offer_ids = { "off_serum_bundle", "off_serum_sub" },

  strings = { en = { name = "Serum", blurb = "A targeted treatment step." } },
}
```

**What stays out of the record:** the brand binding and the *generated display name*. Those
are per-run instance state, not type data — they live in the save (§9).

### 3c. Where each piece lives

| Data | Home | Why |
|---|---|---|
| taxonomy, shapes, offer links, FBX bindings | **content pack** (`products`, `form_factors`) | packable, App-Store-legal, CI-auditable — content.lua's whole purpose |
| validation (frontier lint, ref resolution) | **`content.lua`** (`check_product`, §7) | reuse the boot/CI validator discipline |
| runtime ops (roster, availability, active-base-truth, offer-granting) | **new `sim/products.lua`** | mirrors the `content` (data+validate) vs `economy` (runtime ops) split |
| run instance (roster ids, active id, generated names, develop-wave) | **`game.lua` run state → save** | per-engagement, serialized by the menu/save layer |

---

## 4. How it touches `sim/` — exact integration points

### 4a. Economy/funnel — the active product owns AOV + CVR (the one real change)

Today every ad inherits a global constant: `Game.BASE_TRUTH = { …, cvr_ppm = 24000,
aov_cents = 4500 }` (`game.lua:27`), and `aov_cents` flows untouched through
`Resonance.apply` (`resonance.lua:156`) and `Fatigue.apply_to_truth` (`fatigue.lua:96`) into
`Funnel.sample_impressions`, which on each buy does `ad.revenue_cents += t.aov_cents`
(`funnel.lua:50`). `cvr_ppm` flows the same way, receiving the resonance delta.

**So the single integration point is `Game.compose` (`game.lua:141`):** build a
product-scoped base truth instead of reading the global directly.

```lua
-- sim/products.lua
function Products.base_truth(reg, run)
  local p = Products.active(reg, run)            -- the run's active product record
  local base = {}
  for k, v in pairs(Game.BASE_TRUTH) do base[k] = v end  -- boot-time copy (not sim-tick)
  base.aov_cents = p.aov_cents                   -- product owns the sellable
  base.cvr_ppm   = p.cvr_ppm                     -- product owns the conversion shape
  return base
end
```
```lua
-- game.lua Game.compose, replacing the BASE_TRUTH read:
local base = Products.base_truth(g.reg, g.run)   -- was: Game.BASE_TRUTH
local mods = Resonance.score(lane.rlane, vector)
local truth = Resonance.apply(base, mods)
```

`hook_ppm`, `hold_given_stop_ppm`, `click_given_stop_ppm` stay global — they are funnel
*mechanics* shared by every product. Only the two product-intrinsic knobs move. This is
surgical: no change to `resonance`, `funnel`, `fatigue`, `composer`, or `wave`; the golden
hashes change only because the numbers they consume now come from the product (a deliberate,
documented rebaseline — the demo pack's starter product is tuned to `4500/24000` so existing
fixtures hold, see §10).

### 4b. Content — products gate offer cards; offer effects get wired

Offer cards already exist as kind `offer` with optional `effect` refs
(`content.lua:18-25`): `aov_plus_bundle`, `aov_plus_subscription` are **declared but
unimplemented** — no code reads them. The Product Creator is what gives them teeth:

- A product's `offer_ids` reference offer cards authored in the same pack. Developing the
  product calls `Products.grant_offers` → `col.owned[offer_id] = 1` for each (reusing the
  collection's owned-set, `economy.lua:97`). New product = new sayable, tied to the sellable.
- **Offer effect implementation** (lives in shipped code per content.lua's data-only law,
  applied in `Game.compose` after the wear pass, before the overload pass):

  | effect | implementation at compose | teaches |
  |---|---|---|
  | `aov_plus_bundle` | `truth.aov_cents = floor(truth.aov_cents * 1400/1000)` | bundles raise order value |
  | `aov_plus_subscription` | `truth.aov_cents = floor(truth.aov_cents * 3000/1000)` (LTV) **and** `truth.cvr_ppm = floor(truth.cvr_ppm * 700/1000)` | subs raise LTV but convert harder |

  Both are integer, deterministic, monotone. The subscription CVR drag is the honest tradeoff
  that keeps subs from being a free AOV multiplier (broaden-never-strengthen at the offer
  level too).

### 4c. Naming — reuse `namegen`, don't reinvent

`namegen.product(rng, vertical)` already yields `"{Noun} {Product} No. N"` over the closed
banks (`namegen.lua:146`). The Product Creator binds it: when a product type is chosen, the
display name is generated **once** from a named substream and stored in the save (so load is
stable, no re-roll):

```lua
local rng = Rng.substream(run.seed, "product:" .. product_id)
local display = Namegen.product(rng, vertical)   -- "Dew Serum No. 3"
```
**Constraint:** every product node's `product_noun` MUST be an entry in that vertical's
`bank.product` (lint, §6). For BEVERAGES/MAKEUP, add `bank.product` lists (and the noun/adj/
stem/syll banks) to `namegen.lua` — pure data, CI-lintable against the blocklist like the rest.

### 4d. What products deliberately do NOT touch

- **Layer-1 resonance is untouched.** Products never alter aspect sign classes
  (`resonance.lua:38`) — the curriculum is sacred. Product shape lives entirely in the funnel
  base (AOV/CVR), which is *below* the law, exactly where Layer-2 magnitudes live.
- **Composer/fatigue unchanged** — capacity, combo echo, and wear are about the *creative*,
  not the *product*.
- **No new card kind, no grammar change.**

---

## 5. How a product becomes a playable card / offer (lifecycle)

```
1. CREATE   player picks category → form → starting product in the Product Creator.
2. BIND     run.products = { roster = {id}, active = id, names = {id → generated} }.
            Products.grant_offers(col, product)  →  offer cards enter the collection.
3. ECONOMY  Game.compose reads Products.base_truth → ad inherits product AOV/CVR.
4. SAY      the unlocked Offer cards are now composable in the [Offer] slot like any card;
            their effect refs (aov_plus_bundle/sub) fire in compose (§4b).
5. SHOW     the product's baked toon sprite + brand decal is the [PRODUCT] art layer the
            Ad Composer places "in-hand" (§7).
6. SELL     funnel.lua converts at cvr_ppm, books revenue at aov_cents → autopsy → payout.
7. DEVELOP  later, the Product Lab unlocks the next node (§6) — repeat 2–6 for a new shape.
```

The product itself is never *in* a build; it is the substrate (3,6), the unlocker of Offer
cards (4), and the art layer (5). That is the precise answer to "how a product becomes a
playable card/offer": **it grants Offer cards and sets the economy every ad inherits.**

---

## 6. The tech tree mid-run (Develop) — broaden, never strengthen

### 6a. The invariant (the heart of this system)

Pillar 3 says new products must be **sideways power, not upward** — mirroring the V2 mint's
conserved-total rule. Two CI-lintable guarantees in `content.lua` `check_product`:

1. **Pareto non-domination.** Within a vertical, no unlockable product may dominate another
   in `(aov_cents, cvr_ppm)` — every later node must trade one knob *down* to push the other
   *up*. Formally: for any two products A, B in a vertical, NOT (`A.aov ≥ B.aov` AND
   `A.cvr ≥ B.cvr` AND A ≠ B with at least one strict). A serum has more AOV but less CVR
   than a cleanser; never both.
2. **Revenue-density band.** `aov_cents * cvr_ppm` for every product in a vertical must sit
   within `[850, 1150]/1000` (±15%) of that vertical's **starter** density. This blocks slow
   power-creep: later products are *different*, not *richer*. (Offer effects in §4b are
   excluded from the base record and applied at compose, so a bundle's higher AOV is paid for
   by the offer-card slot + the offer's own CVR character, not free.)

Both are integer comparisons over ordered lists (no `pairs`, sim-safe), run at boot/CI like
the rest of `Content.validate`. This is broaden-never-strengthen as a *test*, not a hope.

### 6b. The Develop action

- **Where:** the Newsstand (between weeks) — the natural broaden-the-toolkit beat — and/or a
  Product Lab excursion from the Desk. MVP: Newsstand only.
- **Cost:** bankroll (R&D spend), reusing `Economy.spend` — no new currency. Suggested tiered
  cost by `tier` (e.g. 20000/40000/80000 cents). Because the invariant guarantees no power
  spike, the unlock can be **immediate** (no development latency) without breaking balance.
  (Latency / "ships next wave" is a deferred flavor option, §11.)
- **Gating:** `requires` prerequisites must be in `roster` (tech-tree DAG).
- **Effect:** add id to `roster`; `grant_offers`; generate+store the display name. The player
  may then set it `active` (free; or a future AP action if per-day switching is added).

```lua
-- sim/products.lua
function Products.can_develop(reg, run, product_id)  -- prereqs met, not owned, in vertical
function Products.develop(reg, run, bank, col, product_id)  -- spend → roster → grant → name
function Products.set_active(run, product_id)         -- which product the run is selling
function Products.available(reg, run)                 -- frontier of developable nodes (UI)
```

---

## 7. Label compositing — brand logo onto the product (local-first)

The hard requirement: the **player-created** brand logo must appear on the product, at
runtime, with **no Blender/ML on device** (local-first, `dynamic-content.md`). Two paths, and
v1 ships the cheap one:

### 7a. Author-time: bake the bare product sprite + the label anchor

`blender_toon_card.py` gets a **PRODUCT mode** (the current code is character-framed:
head→mid-thigh, `blender_toon_card.py:27-33`). Product mode:

1. **Framing = `object`:** center the bbox, fit the whole mesh to the 4:5 frame (no
   head-to-thigh crop). Branch on a `--mode product` arg.
2. **Palette-tintable body:** render the bare product (no decal) so it can be runtime-recolored
   by the brand `palette_id` via the existing recolor shader (`dynamic-content.md §0.4`).
3. **Emit the label anchor:** project the verts of the faces in the `LABEL` material slot
   through the same ortho camera into render-pixel space, take their 2D bbox, write
   `{x0,y0,x1,y1}` to a sidecar `<out>.anchor.json`. This is the rect the runtime decals into.
   (Axis-aligned rect for v1; a 4-corner quad for curved-bottle skew is deferred, §11.)

Output per form-factor: one alpha PNG (bare body) + one anchor JSON. Baked into the atlas.

### 7b. Runtime: flat decal composite (the shippable path)

At runtime, Defold:
1. Renders the **label sprite** = the Brand Creator's logo-kit output (container × glyph ×
   palette × wordmark) — *this compositor is the Brand Creator's deliverable; the Product
   Creator reuses it.* Optionally adds the generated product name as a wordmark line.
2. Tints the bare product body by `palette_id`.
3. Composites the label sprite into the baked `label_anchor` rect (a simple sprite quad).

Result: the player's brand on the product, fully combinatorial, deterministic, zero runtime
ML. This *is* the `[PRODUCT]` layer for the Ad Composer and the product-card thumbnail.

### 7c. Author-time UV decal (optional, shipped/seed brands only)

For the highest-fidelity look (logo *wrapped* on a curved surface), bake the decal onto the
FBX's label UV at author time and toon-render the finished product. This only works for
brands known at author time (seed/marketing brands), so it is **garnish**, not the player
path. The flat composite (8b) is the canonical runtime answer.

---

## 8. Screen flow (design-language v0.1: light FB-blue, chunky-cute, landscape)

### Screen A — Product Creator (at brand creation, after the Brand Creator)

```
┌ NEW BRAND · STEP 2: YOUR FIRST PRODUCT ───────────────────────────┐
│  [vertical: SKINCARE]   (carried from the Brand Creator)           │
│                                                                    │
│  1. CATEGORY      ( Cleanse )  ( Treatment* )  ( Protect )         │  pill row
│  2. FORM/TYPE     [pump bottle] [jar] [spray]   (filtered by cat.) │  chunky chips
│  3. STARTING      ┌────────┐ ┌────────┐ ┌────────┐                │
│     PRODUCT       │ Serum  │ │ Oil    │ │ ...    │  product cards  │
│                   └────────┘ └────────┘ └────────┘                │
│                                                                    │
│  PREVIEW ▶  [ toon product sprite + YOUR logo on the label,       │  live §7b composite
│              tinted to your palette ]   "Dew Serum"   AOV $55      │
│                                          CVR 1.6% · unlocks 2 offers│
│                                                  [ CONFIRM BRAND ] │
└────────────────────────────────────────────────────────────────────┘
```
Picking category prunes form; picking form filters products; the preview is the live §7b
composite (the payoff moment — your logo, on your product). Confirm writes
`run.products` and grants the starter's offers.

### Screen B — Product Lab (mid-run excursion / Newsstand panel)

CK3/heraldry-tree styling to rhyme with the Brand Creator. Nodes = products; states
**owned / developable / locked**; each node shows its silhouette, AOV/CVR shape (two little
meter atoms — reuse the shared meter-bar), the offer cards it grants, and the R&D cost.
"DEVELOP" (blue, agency color) on a developable node spends bankroll and pops the new product
+ its offers into your kit. Active product carries a small "SELLING NOW" chip.

Both screens are assembled from `design/design-language.html` components (product cards, pill
rows, meter atoms, the blue commit button) — invented per the design-from-primitives rule.

---

## 9. Save / determinism (ties to the menu/save designer)

Run-save must include the product roster (already on the menu/save designer's manifest):

```lua
run.products = {
  roster = { "skincare_cleanser", "skincare_serum" }, -- ordered owned ids (ipairs-safe)
  active = "skincare_serum",                           -- which product the run is selling
  names  = { skincare_cleanser = "Dew Cleanser No. 2", -- generated display names (stable)
             skincare_serum    = "Dew Serum No. 5" },
  developed_at = { skincare_serum = 6 },               -- global_wave when unlocked (telemetry)
}
```
Determinism: product *type* data is in the content pack (replays from pack id); the only RNG
is the display-name flourish, drawn from `Rng.substream(seed, "product:"..id)` and persisted
so load never re-rolls. Integer AOV/CVR, ordered lists, no `pairs` in the runtime helpers —
obeys the sim invariants. The product taxonomy itself is **not** journaled (it's static
content); the roster *is* part of the snapshot the save serializes alongside
`bank/collection/wear/desk`.

---

## 10. MVP scope

1. `content.lua`: add `form_factors` + `products` sections and `check_product` validation
   (Pareto + density-band lints, ref resolution, `product_noun ∈ bank.product`).
2. `sim/products.lua`: roster ops, `active`, `base_truth`, `grant_offers`, `develop`,
   `available`, `can_develop`.
3. `game.lua`: `g.products` run state; `Game.compose` reads `Products.base_truth`; offer-effect
   table (`aov_plus_bundle`, `aov_plus_subscription`) applied in compose. Demo pack gains 2–3
   products per its 2 verticals, **starter tuned to 4500/24000** so existing golden fixtures
   only rebaseline where intended.
4. Content: SKINCARE + COOKWARE trees (4–5 nodes each) with their offer cards authored; one
   starting product each. (Software/apparel + beverages/makeup are follow-on packs.)
5. `blender_toon_card.py`: `--mode product` (object framing + label-anchor sidecar JSON).
6. One FBX per v1 form-factor (`pump_bottle`, `jar`, `pan`, `pot`, `device_tile`) with a
   named `LABEL` material slot; baked bare-body sprites + anchors.
7. Runtime flat-decal composite (§7b) reusing the Brand Creator's logo compositor; product
   card thumbnail + `[PRODUCT]` layer hookup for the Ad Composer.
8. Product Creator screen (Screen A) + minimal Product Lab (Screen B) in the component library.

A headless test (mirroring the namegen harness) printing every vertical's tree with AOV/CVR,
density check, and offer grants is the cheapest validation that the frontier feels alive.

## 11. Explicitly deferred

- **Per-ad / per-lane active product** (MVP: one run-level active product). Multi-product
  selling within a week is a v1.x extension to the Ad Builder.
- **Development latency** ("ships next wave") and R&D as an AP-costed Desk action (MVP: instant,
  bankroll-only, at the Newsstand).
- **Curved-surface decal** (4-corner quad / true UV wrap at runtime). MVP = axis-aligned label
  rect; author-time UV bake (§7c) is seed-brand garnish only.
- **Beverages / makeup verticals** — need namegen banks added first.
- **Product provenance / quality tiers** (defer to the team/asset layer in
  `ad-builder-and-assets.md §3`).
- **Software freemium AOV=0 modeling** — v1 uses a paid Starter Plan; true free→paid funnel is
  a later content/economy question.
- **Brand-as-self vs brand-as-client-character ruling** (`brands-and-products.md §3`) — this
  design attaches the roster to *your* run (brand-as-self read); if the ruling lands on
  brand-as-client, the roster simply re-homes onto the client record (the data is identical).
```
