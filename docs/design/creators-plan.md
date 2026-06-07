# Creators — Unified Build Plan (DESIGN, 2026-06-05)

Ties the four creator designs (`brand-creator.md`, `product-creator.md`, `ad-composer.md`,
`menu-save.md`) into one schema, one build order, one set of resolved contradictions, and an
author asset spec. The save IS the brand, so all four read/write **one record**; this doc is the
contract that keeps them from drifting. Grounded in shipped `sim/` (`namegen`, `game`, `economy`,
`content`, `rng`); no creator may feed the 429-test funnel math (identity/presentation only, v1).

## 1. The shared record — one schema (Brand Creator owns it; menu-save persists it verbatim)

```lua
save_run = {                                  -- envelope (saveformat.lua) wraps every file
  magic="ADDM", save_version=1, content_format=1, checksum=0x..,  -- canonical FNV fold
  header = { slot, brand_name, logo, vertical, progress, bank_cents, status, saved_at },

  brand = {                                   -- == Namegen.identity() shape, player-chosen
    schema=1, source="player", seed=0x..,
    name="Hearth & Hew", pattern="amp", vertical="cookware",
    traits={"heritage","cozy","earnest"},     -- 3 of Namegen.TRAITS
    palette_id=3,                             -- 1..8, TOP-LEVEL (namegen parity; logo reads it)
    starting_product="Skillet Dutch Oven No.4", -- namegen seed string; products[] is authoritative once set
    logo={ container="crest", glyph="skillet", font="fraunces", layout="stack" }, -- atom ids → sim/logo.lua
  },
  products = {                                 -- Product Creator owns; IDS ONLY (types replay from pack)
    roster={"cookware_skillet"}, active="cookware_skillet",
    names={cookware_skillet="Copper Skillet No.3"}, developed_at={} },

  run_id, pack_id, bank, collection, minted_cards, ledger, combo_book,  -- game.lua snapshot
  desk, wear, stats, wave={ ... rng_states only mid-FLIGHT ... },       -- (Ad Composer's pose
}                                              -- recipes ride inside minted_cards[].art — no new field)
```

Atoms each system touches: `brand.logo`+`palette_id` → Brand Creator compositor (slot faces,
product label decal, ad logo layer); `products.roster/active` → Product Creator + Game.compose
base-truth + Ad Composer product layer; `minted_cards` → Ad Composer pose recipes + V2 foils.

## 2. Build order (rationale)

1. **Brand Creator (ad-23q, v1, FIRST).** Builds `sim/logo.lua` (baked atoms + `validate` +
   `resolve`) and the compositor — the shared dependency for menu-save slot faces, product
   label decals, and ad logo layers. No upstream deps; fully headless-testable.
2. **Menu/Save (ad-2e7, parallel).** Write/load path is independent of art and must land early so
   the brand is durable from New Game; slot-list **logo render** slots in when (1) lands (placeholder
   mark until then). Owns `run_id` allocation + codex.
3. **Product Creator (ad-66z).** Needs (1)'s compositor for the decal and the author's product FBX.
   Its sim change (`Game.compose` product base-truth + `sim/products.lua` + the two `check_product`
   lints) is headless-testable **now**, ahead of any FBX.
4. **Ad Composer (ad-1i6, v1.x, LAST).** Needs brand+product+rigged characters. Its mechanical
   contract (choice→aspect table + mint helper + `check_card` reuse) is headless-testable now.

**Parallel track, art-independent:** every system's pure-sim contract + golden/lint tests can be
built and merged before any atlas/FBX/rig arrives. Art only gates the Defold screens.

## 3. Contradictions & shared atoms to RESOLVE (canonical = the owning creator's doc)

- **Logo recipe field mismatch (the big one).** `menu-save.md` §3.1/§3.3 store
  `logo={container_id=3, glyph_id="whisk", color_ids={12,4}, font_id=2, layout_id=5}` — **wrong**.
  Canonical (Brand Creator) = `logo={container, glyph, font, layout}` of **string atom ids** plus a
  **top-level `palette_id` (1..8)**. There is **no `color_ids` array** — `palette_id` indexes the baked
  `PALETTES` table; colors never live in the record. Menu-save must store this shape byte-for-byte.
- **`palette_id` location.** One copy, **top-level `brand`** (Namegen.identity returns it there); the
  `logo` recipe references it. Brand Creator doc nesting it under `logo` is superseded — top-level wins.
- **Product record shape.** `menu-save.md` §3.4 inline product (`subcategory`, `tech_tier`, `name`,
  `fbx_id`, `label_decal_ref`) is **wrong**. Canonical (Product Creator): type data
  (`vertical/category/form/tier/requires/aov_cents/cvr_ppm/offer_ids`) lives in the **content pack**;
  the save holds only `products={roster,active,names,developed_at}` (ids). `form_factors[]` owns
  `fbx`+`label_anchor`. Drop `color_ids`/`label_decal_ref` — the decal is the live logo composite.
- **`starting_product` vs roster.** `brand.starting_product` is the namegen seed STRING (fallback);
  once Product Creator runs, `products.roster[1]` (a node id + generated `names[id]`) is authoritative.
- **Color-law firewall (shared rule).** Brand `palette_id` colors render **only** on logo/brand-art/
  label/ad-art surfaces — never chrome (green=money, red=fatigue, blue=agency). Enforce in all four.
- **Versioning.** `brand.schema` is a sub-schema; the envelope `save_version`/`content_format` govern
  migrations + the alias/retired-id table (ship empty in v1). One alias table, owned by saveformat.
- **5-day vs 7-day week** (`game.lua` `days=5` vs Mon–Sun loop): autosave keys off `day_end` events
  regardless of count; flagged for the loop owner, does not block the creators.

## 4. Author asset deliverables (so they're ready when product assets land)

**Product FBX, one per v1 form-factor** (`pump_bottle`, `jar`, `spray_bottle`, `pan`, `pot`,
`blade`, `device_tile`; MVP subset = pump_bottle/jar/pan/pot/device_tile):
- **Format** `.fbx` (matches the Artlix→Blender toon pipeline / `blender_toon_card.py`).
- **Scale/orientation** real-world-consistent, +Z up, mesh centered on origin; the script object-fits
  the bbox to the 4:5 ortho frame, so consistent scale across a set keeps relative sizes honest.
- **Two material slots, named:** `BODY` (palette-tintable — kept decal-free so the recolor shader
  works) and **`LABEL`** (the faces that carry the brand mark).
- **Label UV** clean and roughly planar on the `LABEL` faces; v1 assumes an **axis-aligned label
  rect** (curved-bottle 4-corner quad is deferred) — flat-front labels read best.
- Pipeline bakes per FBX: one alpha bare-body PNG + a `<id>.anchor.json` (`{x0,y0,x1,y1}` label rect).
- Also needed for Ad Composer (later): rigged character FBX (Artlix C3CP route) with the upper-body
  bones `blender_puppet_slice.py` slices; product grip-anchor per form. (tracked: ad-ccm, ad-1i6.)

## 5. Mocks-first task list (filed in beads under the existing epics)

Per the design-from-primitives rule, each screen ships as a `design-language.html` mock first, with
the headless sim contract built in parallel. Filed children:
- **ad-23q:** screen mock · `sim/logo.lua`+`test_logo.lua` · logo/logo_marks atlases + Fraunces/Archivo SDF · Defold `logo` GUI scene.
- **ad-2e7:** slot-list + New-Game-wizard mock · `sim/serialize.lua`+`sim/saveformat.lua`+golden save test · `game/save.lua` I/O + autosave hooks · adopt §3 canonical logo+products shape.
- **ad-66z:** Product Creator + Product Lab mocks · `content.lua` form_factors/products + `check_product` lints · `sim/products.lua` + Game.compose base-truth + offer-effect table · `blender_toon_card.py --mode product`.
- **ad-1i6:** choice→aspect table + mint helper (headless now) · composer excursion mock · `blender_puppet_slice.py` + 2D puppet canvas (post-assets).
