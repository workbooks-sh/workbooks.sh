# The Ad Composer — player-posed ad visuals (DESIGN, 2026-06-05)

**Status: author-ruled into scope (DECISIONS 2026-06-05 "idle anims dropped → player Ad Composer"), spec'd here. v1.x — sequenced AFTER Brand Creator (v1) and Product Creator. Build order + dependencies in §9.**

The Ad Composer is the third of the four creators (Brand → Product → **Ad Composer** → Menu/Save). It replaces the dropped idle-animation library: instead of authoring N canned poses per character and fighting retargeting, **we ship rigged characters and the player poses them**. The player drags a character's arms/head into a pose, puts a product in its hand, picks a setting/surface, places brand + card text, and the result becomes a **Visual asset card** that drops into the existing `[Hook][Visual][Format][Offer]` ad grammar.

This is the layered-art system (`brands-and-products.md §4`, `dynamic-content.md §0.4`) made **interactive**: the same setting × person × product alpha layers, but the person layer is now a poseable puppet and the choices mint a real card.

---

## 1. The one load-bearing distinction: craft vs. choice

The composer has two kinds of input, and they map to two different worlds. Getting this line right is what keeps the feature buildable, deterministic, and pedagogically honest.

| Input | Example | Where it lives | Affects the sim? |
|---|---|---|---|
| **Discrete choice** | which character, which *pose intent* (demo/testimonial/lifestyle), which product-in-hand, which setting | a baked **choice → aspect** table | **YES** — becomes the Visual card's aspect vector, scored by `resonance.lua` |
| **Continuous craft** | exact shoulder/elbow/head angles, exact text placement, palette nudge | the **pose recipe** (presentation data) | **NO** — never read by any sim module; pure expression |

So: **the player's discrete choices are graded by the existing aspect taxonomy; the player's hand-craft is never graded.** This sidesteps the trap the Ad Builder doc already rejected for copy (`ad-builder-and-assets.md §4`: "writing real copy and grading it is the obvious trap") — we never score "is this a good pose." Posing is the *cute, expressive, retargeting-killing* act; the mechanics ride on the handful of menu picks underneath it. It also mirrors the standing repo law (DECISIONS 2026-06-05 dynamism): **runtime presentation output is presentation-only, forever.** Pose data is exactly that.

This line also protects pillar 3 (broaden, never strengthen): a composed Visual is **sideways power** — its aspects come from bounded baked tables, capped at the same 1–4 aspects / 1–5 pts every stock card obeys (`content.lua` `check_card`). The composer broadens what you can *show*; it never mints a strictly-better card. (Same discipline as `economy.lua`'s V2 foil mint — "point moves, never strict upgrade," proven over 50 seeds in `test_economy`.)

---

## 2. What is poseable (keep it simple — author ruling)

FK only — **no IK, no retargeting** (the whole point of the ruling). Six drag handles on the upper body, the parts that read at ad scale:

```
            (head)
              │
         ┌──(spine)──┐
   (sh_l)│           │(sh_r)        sh = shoulder
        │             │             el = elbow
   (el_l)│           │(el_r)        L/R = character's own left/right
        │             │
     hand_l        hand_r ← product socket
              │
          (legs: one static piece — not poseable in v1.x)
```

- **6 poseable bones:** `spine`, `head`, `sh_l`, `el_l`, `sh_r`, `el_r`. Wrists, fingers, legs, and facial bones are **not** poseable in MVP (legs are a single static lower-body piece; the ad framing is roughly head-to-mid-thigh per `blender_toon_card.py`'s ortho 4:5 crop, so legs barely show anyway).
- **Each handle rotates its bone (FK)** — rotating `sh_l` swings the whole left arm; `el_l` bends only the forearm. Drag = rotate; **snap to detents** (e.g. 15° steps) on release. Snapping is both a determinism/size win and a *feel* win: it matches the chunky-cute "everything snaps with a haptic" language (`design-rules.md §4` shelf-press, `§5` snap ≤120ms + Voice haptic). Posing should feel like clicking a wooden artist's mannequin into place, not nudging pixels.
- **Pose presets** seed the body so nobody starts from a T-pose: tapping a preset ("Demo", "Testimonial", "Lifestyle", "Unbox", "Hold-up") snaps all six bones to a baked starting pose, which the player then tweaks. The preset *also* carries the **pose-intent id** — the one discrete, mechanically-meaningful pose fact (see §1). Tweaking the angles afterward changes the look, never the intent.

---

## 3. Data model

Two artifacts: the **recipe** (presentation, deterministic data) and the **minted card** (the sim object).

### 3.1 The pose recipe (lives on the Visual card's `art` field — data-only)

```lua
-- Deterministic: integers + string ids only. NEVER read by resonance/funnel/economy.
-- Passes content.lua's no-functions deep scan trivially (no functions, no surprises).
recipe = {
  recipe_format = 1,
  character_id = "ugc_f_01",          -- baked puppet archetype (person layer)
  wardrobe_id  = "casual_02",         -- optional clothing/palette variant (baked)
  pose = {                            -- FK bone rotations, quantized degrees, -180..180
    spine = 4,  head = -6,
    sh_l = 22,  el_l = 40,
    sh_r = -18, el_r = 30,
  },
  hold = {                            -- product-in-hand (optional)
    product_id = "dew_serum_no3",     -- from the run's product roster (Product Creator)
    socket = "hand_r",                -- which hand bone hosts the grip
    grip_id = "grip_bottle",          -- baked grip offset+rotation preset for that product shape
  },
  setting_id = "kitchen_morning",     -- baked background layer
  surface_id = "counter_marble",      -- baked surface/prop layer (optional; may fold into setting)
  decals = { logo = "brand_logo" },   -- Brand Creator logo-kit output, composited as a decal
  text = {                            -- PLACED preset copy — never free text (see §6)
    { slot = "wordmark", anchor = "tl" },
    { slot = "headline", from_card = "hook_pain", anchor = "top_strip" },
    { slot = "cta",      from_card = "off_trial", anchor = "cta_chip" },
  },
  pose_intent = "demo",               -- the ONE discrete pose fact that feeds aspects
}
```

### 3.2 The minted Visual card (the sim object — obeys `content.lua` exactly)

```lua
card = {
  id = "vis_c_" .. choice_hash,       -- stable, snake_case (^[a-z][a-z0-9_]*$), collision-checked
  kind = "visual",
  rarity = "common",                  -- composed visuals are common-tier (sideways, not upgrade)
  weight = 2,                         -- flat v1.x (matches stock visuals in game.lua demo_pack)
  aspects = { {"social_proof",2}, {"mechanism",1} },  -- summed from the choice→aspect table, capped 1..4 / 1..5
  strings = { en = { name = "UGC Demo · Kitchen" } }, -- auto-derived via namegen grammar (§7)
  art = recipe,                       -- the presentation recipe above
}
```

### 3.3 Identity rule (the critical buildable detail)

`card.id` is a stable hash of the **mechanically-meaningful subset only**: `(character_id, pose_intent, hold.product_id, setting_id, surface_id)`. The raw `pose` angles and exact `text` anchors are **cosmetic deltas under that identity** — they do *not* change the id.

Why this exact rule:
- **It keeps `composer.lua`'s combination-fatigue honest.** `Composer.combo_key` sorts card ids; combination wear keys on the composed *set*. If a 2° elbow nudge minted a new id, players could dodge the Andromeda echo-penalty with cosmetic noise. Keying identity on the discrete choices means **a real creative change (new intent / person / setting / product) is a fresh combo at baseline; a cosmetic re-pose is the same ad** — which is exactly the truth ("near-duplicates stagnate," `ad-builder-and-assets.md §7`).
- **It bounds the asset library.** Two visuals with the same five choices collapse to one card — no near-dup id explosion in the collection or save.
- **Mint is idempotent.** Re-composing the same choices returns the existing owned card (and may just update its cosmetic recipe), like a no-op pack pull.

---

## 4. How it touches `sim/`

The composer is overwhelmingly **presentation** (a Defold editor + baked assets). Its only sim surface is *minting a valid card* and *one baked data table*. Nothing in the deterministic core changes.

| Module | Touch | Detail |
|---|---|---|
| `composer.lua` | **none** | A composed Visual is a card with a `weight`; it flows through `over_by` / `legibility_x1000` / `combo_key` unchanged. Capacity math doesn't care how the card was made. |
| `resonance.lua` | **none** | Scores the minted card's aspect vector like any card. Pose angles are invisible to it. |
| `content.lua` | **mint-time validation** | Reuse `check_card` to validate the minted card (id regex, kind, rarity, aspects 1..4 from the taxonomy, `strings.en.name`, no functions). Custom ids checked against pack ids + `retired_ids`. The `art` recipe is data → passes the no-functions scan. |
| `economy.lua` | **collection mint** | The Visual lands in `collection.owned[id] = 1` (same place pack pulls / V2 mints land). It can fatigue/scar per-lane and can itself be foiled (V2) if it becomes a fatigued winner + IP — free synergy. Mint discipline = `economy.lua`'s "never strictly better" law. |
| `namegen.lua` | **auto-name + flavor** | The card name and the ad's flavor line reuse the grammar over the chosen layer tags (`dynamic-content.md §0.2`: "`{person.descriptor}` demos `{product.name}` in `{setting.descriptor}`"). No free text needed. |
| `game.lua` | **uses, unchanged** | `Game.compose(g, card_ids)` already sums aspects and applies capacity/fatigue. A custom Visual id in `card_ids` just works. |
| **NEW baked data** | `content/` choice→aspect table | A pure-data lookup: `character_id → aspects`, `pose_intent → aspects`, optional `setting_id → small aspect nudge`. Ships in the content pack, lint-able like the namegen banks. **No new sim module required** for v1.x; the mint helper can live beside the V2 mint in `economy.lua` or in a thin `sim/mint.lua`. |

**Determinism statement (for `docs/02-technical.md`):** pose recipes contain quantized integers and string ids only and are *never inputs to a sim function* — they ride along on the card as `art`. The sim contract remains "aspects in, ppm out." Pose data therefore cannot perturb the integer sim, cannot break replay, and is screenshot-safe across devices (same recipe → same layered render, the same guarantee Tier-0 already gives logos and brand art).

---

## 5. Rendering & pipeline — the real decision

The composed visual is **flat layers all the way down**, which is the cheap, Defold-native, determinism-safe choice — and it's the *same* layered-art system already ruled in, just with the person layer split into poseable parts. Recommended v1.x route is the **2D cutout puppet**; the 3D route is noted as the heavier alternative.

### Route A — 2D cutout puppet (RECOMMENDED for v1.x)

The character is pre-sliced at **author time** into ~7 alpha part-sprites (head, torso, upper-arm L/R, fore-arm+hand L/R, static lower body), each with a recorded **pivot = joint**, assembled in Defold as a nested node/GO hierarchy. Posing rotates the parent nodes (FK). The whole scene — setting bg → surface → posed parts → product → decals → text — is just stacked alpha layers, identical in the editor and on the card.

- **Edit time:** live nested GUI nodes (or a small GO hierarchy), no render target. ≤6 rotations + ~12 sprites is trivial to drive at 120Hz while dragging (`design-rules.md §5` law 4; watch `defold#8571` iOS touch-drag stutter, already a tracked risk).
- **Card display:** on **commit**, optionally flatten the layer stack to one cached texture (`render.set_render_target` once) so the Desk can show many ads without per-frame re-compositing — and so the ad card sits *still* (no idle wobble; `composed-ad.md §6` "rest: none"). The cached texture becomes the composed-ad board card's "visual region" (`composed-ad.md §1`, upgrading the emoji-placeholder visual well to the real scene).
- **Asset pipeline:** new author-time tool `tools/blender_puppet_slice.py`, sibling to `blender_toon_card.py` — same toon material + ortho framing, but renders the character in a neutral pose and exports per-part alpha PNGs + a pivot/z-order manifest. Toon look is baked in (no runtime shader needed).
- **Cost / limits:** 2D FK can't foreshorten (an arm can't point at the camera) and limb z-order must be authored per archetype. For a flat stylized toon at ad scale this is a *stylistic fit*, not a compromise — and it's a fraction of the runtime cost of skinning.

### Route B — runtime 3D toon model + render-to-texture (DEFERRED alternative)

Load the Artlix FBX-derived mesh + skeleton as a Defold `.model`, pose real bones, render the posed character to an offscreen texture on commit, composite with flat setting/product/text layers. More expressive (true 3D posing, foreshortening) but: the Blender toon ramp must be **re-implemented as a Defold runtime material/shader** (the author-time bake doesn't transfer), per-edit-frame skinning is heavier, and render targets are mandatory. Reserve for a v2 "studio" tier if 2D FK ever feels too flat.

**Either route, the ad card shows a baked snapshot** — interactive 3D/2D only exists inside the composer; the rest of the game sees a still image. This keeps the Desk cheap and the "nothing pulses at rest" law intact.

---

## 6. Text — reconciling "add text" with "no free-text copy"

The author ruling says "add text"; `ad-builder-and-assets.md §4` says **no free-text copywriting in v1** (it would need an LLM/server, breaking local-first, and can't be graded honestly). Both hold, because composer text is **placement, not authorship**:

- **Wordmark** — the Brand Creator's brand name in its chosen display font, placed as a layer.
- **Headline / CTA** — the *already-chosen* copy that lives inside the ad's Hook and Offer cards (`ad-builder-and-assets.md §4`: "copy lives inside hook/angle cards — their names and flavor ARE the copy"). The composer lets the player *position and style* (anchor + preset style) that existing copy on the scene; it never asks the player to write new words.

So "add text" = choosing which of the ad's existing strings appear on the visual and where — a layout act with zero free-text surface. (Free-text "pitch mode" remains the same forever-parked post-v1 idea it already was.)

---

## 7. Screen flow

The Ad Composer is an **excursion that mints a Visual asset into your collection** (like a pack rip mints cards), reached from the Builder's Visual slot or from the Desk. Decoupling it from the per-ad Build keeps the Builder fast (drag cards into slots) and matches the existing asset-library model (`ad-builder-and-assets.md §3`: team mints assets → library → builder). It is built entirely from `design-language.html` components.

```
DESK / AD BUILDER (flows.md screen 3/4)
   └─ tap Visual slot → "Compose a visual" ─→ ╔═ AD COMPOSER (excursion) ═══════════════╗
                                              ║ CENTER  the composition canvas (4:5):    ║
                                              ║   setting bg → surface → posed puppet →   ║
                                              ║   product-in-hand → logo decal → text     ║
                                              ║   6 chunky joint handles (tap→drag→snap)  ║
                                              ║ LEFT rail (card shelves): Character ·      ║
                                              ║   Wardrobe · Pose preset                  ║
                                              ║ RIGHT rail: Setting · Surface · Product · ║
                                              ║   Text/Logo presets                       ║
                                              ║ FOOT: derived aspect tags ("social_proof  ║
                                              ║   +2 · mechanism +1") · auto name ·        ║
                                              ║   resulting WEIGHT · [MINT] (blue, agency) ║
                                              ╚═══════════════════════════════════════════╝
                                                   └─ MINT → validated Visual card added to
                                                      collection → return to Builder, ready to drop
```

- **Pickers are card shelves** (cards are the UI, rule 1): Character/Wardrobe/Setting/Surface/Product/Pose-preset each present as small cards; the Product shelf draws from the run's roster (Product Creator output).
- **The foot shows the mechanics live** (real metric names, rule 5): as the player changes discrete choices, the derived aspect tags and the resulting card weight update, so the player sees *what the visual will say* and *how heavy it is for the capacity budget* (`composer.lua`) **before** minting.
- **Editing relaxes "one thing at a time."** The settle-pass law (rule 3) governs *resolution ceremonies*; a creation surface is interactive by nature. The single ceremony beat here is the **MINT** (a snap + Voice haptic, the card seating into the collection). Inside editing: drag = pose, tap a shelf card = swap that layer, tap a pose preset = whole-body snap, a Reset verb returns to the preset.
- **AP / cost:** minting a custom Visual is a *production* action. Lean: free or a small bankroll "production cost" pre-engagement (consistent with `ad-builder-and-assets.md §8` open-q2 on asset-generation cost) — flagged tunable, not a per-day AP sink, so the creative act never competes with the day's 3 AP.

---

## 8. MVP scope (v1.x) vs. explicitly deferred

### v1 baseline WITHOUT the composer (the fallback — the game ships playable)
Visual cards ship with **one baked author-time pose each** (today's `blender_toon_card.py` alpha card). No posing. The composer is purely additive; nothing depends on it to be playable.

### v1.x Ad Composer MVP
- **2D cutout puppet** (Route A), **1–2 fully-rigged character archetypes**.
- **6 FK drag handles** (both shoulders/elbows, head, spine), snap-to-detent, ~5 pose presets carrying pose-intent.
- **One product-in-hand socket** (`hand_r`), product from the run roster, snaps into a baked grip.
- **Setting picker** (~6 baked backgrounds) + optional surface picker (~4, or folded into settings).
- **Text = placement of wordmark + the ad's existing Hook/Offer copy** (no free text).
- **Mint → validated common-tier Visual card** into the collection; discrete choices → aspects via the baked table; flat weight 2.
- **Render:** live 2D layers in-editor; flatten to a cached texture on commit for the ad card / Desk.

### Explicitly deferred
- **Route B 3D posing / render-to-texture / foreshortening** — v2 "studio" tier.
- **IK** — never (FK only is the ruling).
- **Free-text copy** — forever-parked (the §6 line holds).
- **Pose *quality* grading** — we grade discrete choices, never craft.
- **Facial expressions / blendshapes** — maybe a small preset face picker later; defer.
- **Pose/layer-count → weight coupling** ("more layers = heavier = clutter penalty") — truthful and tempting, but start flat; tune after the capacity budget is felt in playtest (`ad-builder-and-assets.md §8` open-q1).
- **Multi-character scenes, second hand/second product.**
- **Animated poses** — it's a still; idle anims are dead and stay dead.
- **Near-dup pose detection** feeding combination fatigue — the §3.3 identity rule already gives the honest behavior with zero similarity math; Tier-1 affinity tables (`dynamic-content.md §0.4` / TIER 1) could refine it later, baked, free.

---

## 9. Sequencing & dependencies (flag, per the brief)

This is a **v1.x feature, after Brand Creator (build first, v1) and Product Creator.** Three hard upstream dependencies, each gating part of the composer:

| Depends on | Provides | Gates |
|---|---|---|
| **Rigged character assets** (`character-art-routes.md` — Artlix C3CP FBX route) | the puppet source meshes | everything; needs `tools/blender_puppet_slice.py` (new) on top of the existing toon pipeline |
| **Product Creator** | products with brand decals + flat cutouts + a grip anchor | product-in-hand (`hold`) |
| **Brand Creator** (v1) | the logo-kit recipe | the `decals.logo` layer + the wordmark text |

Build order within the composer: (1) the choice→aspect baked table + mint helper + `content.lua` validation reuse (pure sim, testable headless *now*, ahead of any art); (2) `blender_puppet_slice.py` + 1 character; (3) the 2D puppet canvas + 6 handles + presets in Defold; (4) setting/product/text layers + MINT; (5) cached-texture flatten for the Desk. Steps (1) can land and be unit-tested in the `sim/` suite before any asset exists — the mechanical contract is independent of the art.

---

## 10. Open questions

1. **Production cost of a mint:** free, flat bankroll cost, or an AP cost? (Lean free/bankroll — keep it out of the 3-AP day.) — ties to `ad-builder-and-assets.md §8` q2.
2. **Setting aspect contribution:** does setting feed aspects at all, or is it pure flavor? (Lean: small social_proof/novelty nudge for a few settings, most flavor-only — keep the lesson on hook/visual intent.)
3. **Pose-intent count:** how many intents (demo/testimonial/lifestyle/unbox/hold-up…)? Each is a row in the baked table and a starter pose to author.
4. **Does the player see the layers snap, or just the result?** (`brands-and-products.md §6` q5.) Composer says **see it** — the snapping IS the toy; but the ad card shows only the flattened result.
5. **Weight coupling** (deferred above): if/when "more layers = heavier," what's the curve, and does it route through `composer.lua` capacity or a separate clutter term?
