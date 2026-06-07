# SPEC — The Component Card (`.ccard`)

> Assessed against `design/design-rules.md` v1.0, `design/design-language.html` v0.1,
> `docs/01-game-design.md` §4, `docs/research/cards.md` §2.3–2.4, `docs/research/mobileux.md` §2/§5.
> Sim modules rendered: `sim/content.lua` (kind, name, art), `sim/resonance.lua` (aspect tags),
> `sim/economy.lua` (rarity, IP → V2 mint), `sim/fatigue.lua` (wear, scars, retire).
>
> **Verdict: REFINE.** The base anatomy is right and already collectible-pretty. The gaps are
> state coverage (modifier kind, fatigue stage 2, scars, interaction states, card back) and one
> system conflation (foil V2 ≠ legendary).

---

## 1. Criteria scorecard

| Axis | Score | Notes |
|---|---|---|
| Minimal | 4.5/5 | Kicker + art + name + tags, no numbers on the card (Snap restraint, correct). Only flourish: the rotated V2 flag — keep, but drop its `✦` glyph (icon ruling) and pull it inside the card bounds (it currently overflows `top:-9px/right:-7px`, will clip in fanned hands and atlas-rendered grids). |
| Effective | 3/5 | Renders 4 of 5 kinds, 1 of 2 fatigue stages, 0 of 3 scars, no interaction states, no card back. The card cannot yet tell the player "one more cycle and this retires" — a real decision input. |
| Cute | 4.5/5 | Kind-tinted pastel art wells + emoji placeholders + chunky 2.5px border are the cutest thing in the library. Spent `🪦` is exactly the tone. |
| Beautiful | 4/5 | "The border speaks" rarity ladder is genuinely lovely; foil restrained to the art well is the right Balatro take. Shop singles betray it — see §6. |

---

## 2. Anatomy (locked, from v0.1)

| Atom | Spec | Source |
|---|---|---|
| Frame | 132×182, `radius/card` 16px, `--card` fill, 2.5px border (rarity recolors it), `shadow/rest` | — |
| Kicker | kind name, Nunito 800 caps 9.5px, +1px tracking, `--dim` | `sim/content.lua` |
| Art well | 72px tall, radius 10, kind-tinted, art glyph 36px (Noto emoji placeholder per icon ruling §3.2) | `sim/content.lua` |
| Name | Baloo 2 700 14.5px, **clamp 2 lines** | `sim/content.lua` |
| Aspect tags | pill `radius/pill`, 9.5px 800, `name + magnitude`; 2–4 per card, bottom-anchored | `sim/resonance.lua` |
| V2 flag | gold tab, "V2" text only (no glyph), 6° rotation, **inside** the top-right corner | `sim/economy.lua` |
| Scar marks | NEW — see §4 | `sim/fatigue.lua` |

**No numbers on the card** except tag magnitudes. Revenue lives on the ad tile; fatigue meters
live in the inspect drill-in. Negative magnitudes render as the literal signed number
(`trust −1`) in the same pill — no special treatment, the minus IS the information.

---

## 3. Kinds — FIVE, not four (finding)

`docs/01-game-design.md` §4: `Ad = [Hook][Visual][Format][Offer] + ≤3 modifiers`. Modifiers are
**24 cards of the ~150 v1 set** (≈15%) — bought in shops, held in hand, attached to proven ads.
v0.1 has no `k-modifier` tint and no example. The design-rules derived-tints table must gain one.

| Kind | Art tint | Status |
|---|---|---|
| HOOK | `#fdebe2` | shipped |
| VISUAL | `#e3f1fd` | shipped |
| FORMAT | `#eee9fb` | shipped |
| OFFER | `#e4f4e9` | shipped |
| **MODIFIER** | **`#fdf3dd` (amberpale family — "attaches to," rhymes with the IP pill)** | **ADD** |

When attached to an ad, a modifier renders as a **charm pip** on the ad tile (a small round
token in the modifier tint, max 3) — that micro-form belongs to the Composed Ad group; this
group owns only the full card. Tint value is a proposal — confirm it doesn't collide with the
warn-chip reading before locking.

---

## 4. State model — three independent axes + interaction

The card's states are a cross-product of three *independent* axes. The library currently
entangles two of them (finding #1).

### Axis A — Rarity (identity, `sim/economy.lua`). The border speaks.
| Tier | Treatment |
|---|---|
| common | 2.5px `--line2` border |
| uncommon | 2.5px `--blue2` border |
| rare | 2.5px `--gold` border + gold-tinted shelf shadow (`0 2px 0 #9a7424`, ambient at 18% gold) |
| legendary | rainbow gradient border (shop-excluded; the white whale) |

### Axis B — V2 foil (identity, `sim/economy.lua`) — **orthogonal to rarity**
**FINDING (top):** the v0.1 caption and design-rules §6 say "foil V2 = legendary + shine."
Wrong per the sim: a V2 is minted from **any** fatigued winner + Iteration Points — a *common*
Pain Point V2 is a foil common. Foil = V2 marker, stackable on every rarity tier.
- Treatment: shine sweep across the **art well only** (deliberate restraint — keep), 3.2s
  ease-in-out loop, + the V2 flag. Border stays whatever rarity says.
- **Multi-foil rule:** ambient loops cap at ~2/screen (motion law 1). Excess foils render
  **frozen shine** — the specular gradient parked at the 47% position, no animation. Foil still
  reads; the screen stays calm. Priority: most recently played/acquired card animates.
- Fix the line in `design-rules.md` §6 when this spec lands.

### Axis C — Fatigue lifecycle (state, `sim/fatigue.lua`). State is treatment — full-card filter only.
| State | Treatment | Gap |
|---|---|---|
| FRESH | full color | shipped |
| CREATIVE LIMITED | `saturate(.55)`, art at 65% opacity | shipped (rename class `.worn` → `.limited`; rule 5: Meta's literal words) |
| **CREATIVE FATIGUE** | **`saturate(.35)`, art at 50% opacity** | **ADD — chips have stage 2, the card doesn't** |
| SPENT | `saturate(.2)`, whole card 75% opacity; retires into Learnings | shipped |

- **Scars (0–3), permanent, global:** NEW. Each completed wear cycle renders one **dog-eared
  corner** — a small (~10px) clipped-corner paper-fold in `--line2`, applied top-left → top-right
  → bottom-left. This is a re-treatment of the card's own corner pixels (rule 2 compliant: not a
  badge, not an overlay), countable at a glance, and physically cute. At scar 3 the card is
  retiring — the player must be able to *count down to it*. (Fallback if dog-ears fail in
  playtest: 1–3 tiny `--dim` notch ticks in the kicker row.)
- **Per-lane context rule:** wear is per-card-**per-lane**. The desaturation filter renders the
  wear of the *contextual lane* (builder targeting a lane, ad tile in a lane). In lane-less
  contexts (shop, codex, learnings) the card renders FRESH treatment + its scars — scars are the
  only global fatigue truth.
- Supersedes `cards.md` "VHS tracking noise" visualization — that line belongs to the dead CRT
  direction; desaturation is the ruling (design-rules §6).
- Foil × worn stack order: the fatigue filter wraps the **entire card including foil/border**
  (honest — even your foil fades). Shine keeps looping through LIMITED/FATIGUE, **stops at SPENT**.

### Interaction states (the card is the game's primary touchable) — **all missing in v0.1**
| State | Treatment |
|---|---|
| rest | as anatomy |
| pickup/drag | lifts above the finger, scale 1.15×, shadow deepens (ambient blur ×2); 120Hz while tracking |
| slot-hover | card leans toward slot (~3° tilt); slot glows |
| seated | snaps to slot; see §5 |
| inspect | pop to 1.1× centered, rest of screen dims; opens drill-in |
| unaffordable (shop) | standard disabled desaturation `#c9cfdd`-family, price pill stays legible — never hidden |

---

## 5. Animation — what the card owns

Vocabulary per design-rules §5. One thing at a time; all lifecycle changes fire **only inside
the End-Day ceremony queue** — the card never changes state mid-plan (no anxiety motion, law 5).

| Motion | Trigger | Spec | Haptic |
|---|---|---|---|
| pickup | touch-down + drag start | pop, ~180ms ease-out to 1.15×, lifts above finger | Whisper |
| hover detent | enters slot zone | lean ~3°, once per slot entry | Whisper (detent) |
| snap | release over slot | **snap**, ≤120ms, slight overshoot, seats into slot | Voice (same frame as click SFX) |
| return | release over nothing | **return**, ~250ms spring back to hand | — |
| inspect pop | tap | **pop**, ~180ms ease-out, 1.1× | Whisper |
| wear advance | ceremony queue item (fatigue stage tick) | filter cross-fades over ~250ms while its chip advances; one card at a time | Voice — fatigue double-knock (low woodblock ×2) |
| scar mint | ceremony queue item (cycle completes) | dog-ear folds in, ~250ms return-spring | Voice |
| retire → Learnings | ceremony queue item (3rd scar) | SPENT treatment lands, then card collapses out via **return** toward the Learnings ledger | Voice (heavy, soft sharpness — don't punish twice) |
| pack-rip reveal | shop ceremony | **setpiece** 700–1100ms: card back flips to face; rare+ adds a beat of hang-time before the flip | **Shout** (≤1/10s; keyframe + SFX + haptic same frame, haptic never leads) |
| V2 mint | spend IP + fatigued winner | **setpiece**, pack-rip amplitude: old card's filter burns off → foil shine's first sweep plays as the reveal | **Shout** |
| foil shine | ambient (V2 identity) | 3.2s ease-in-out loop, art well only; frozen-shine variant past 2 loops/screen | none (state, not event) |

Rarity has **no** motion — it is identity, the border speaks silently. Shimmer belongs to
metrics (`sim/shimmer.lua`), never to this card.

---

## 6. Overlap — merge/share rulings

| Other component | Relationship | Ruling |
|---|---|---|
| `.minislot` (Composed Ad, 34×46) | IS this card's micro variant | **Claim it.** Share the kind tint: minislot background becomes the kind's art tint (recipes then read by color at a glance); empty slot = dashed border in the *expected kind's* tint. Shares the art glyph. Lives in the Composed Ad group but inherits tokens from here. |
| `.pricetag` shop single (`🔥 Pain Point $50`) | duplicates card identity as a text row | **Stop using it for cards.** The most important object in the game must not flatten to a list row at the moment of purchase — shop singles display the real `.ccard` with a price pill beneath. `.pricetag` survives for non-card goods (upgrades) only. |
| `.tag` pills | shared atom with hire traits | Keep shared. Tag tint maps to **aspect axis** (taxonomy = 5–6 axes), one pale field per axis — assign the mapping when the taxonomy locks; the rare example's `compare` borrowing the trust tint is exactly the drift this prevents. |
| `.pack` | the card's container | Card back (§7) echoes the pack's blue + zig so rip → flip reads as one material. |
| spent-gray treatment | shared with chips, pips, codex-unseen | Keep on shared tokens (`#ececf1`/`#9a9aa8` family). |

---

## 7. Variants — default NO; three earn a yes

| Variant | Verdict | Justification |
|---|---|---|
| Full card 132×182 | YES (default) | hand, builder shelf, shop, codex, learnings |
| Minislot 34×46 | YES (exists; claimed in §6) | ad tile recipe stack on table/flight screens |
| **Card back** | **YES — ADD** | pack-rip flips need a face-down state; fanned hand idles face-down (table mockup). One design: `--blue`→`#2c4170` gradient + the pack's zig motif. No rarity tells on the back (the flip IS the reveal). |
| Badge/icon-only form | NO | no screen needs it; the minislot already covers micro |
| List-row form | NO | rejected per §6 — the card never flattens |

---

## 8. Implementer notes (Defold)

- Fatigue states = one desaturation shader on the card's GUI node tree (filter applies to
  border + art + tags together; matches the CSS `filter` behavior of v0.1).
- Foil = white specular quad scrolling under a stencil mask clipped to the art well; frozen
  variant = same quad parked at 47%.
- Legendary rainbow border = 9-slice with a pre-baked gradient texture (don't shader-animate it;
  rarity is static).
- Dog-ear scars = corner overlay quads from the atlas, tinted `--line2`; 3 prebaked positions.
- V2 flag must live inside the 132×182 rect for clean atlas packing and hand-fan clipping.
- Touch: 132×182 ≫ 48dp minimum; drag at 120Hz, settle to 60 (mobileux §5).
- Art emoji ship as Noto Emoji PNGs in the atlas; kicker/tags/name are SDF text. No icon glyphs
  on the card surface (icons-and-emoji-never-share-a-surface rule).

## 9. Findings index

1. **Foil V2 conflated with legendary** — V2 mints at any rarity; disentangle (also fix design-rules §6).
2. **MODIFIER kind missing** — 5th kind, ~15% of the card set; add tint + exemplar.
3. **CREATIVE FATIGUE (stage 2) missing on the card** — chips have it, card doesn't.
4. **Scars unrendered** — 3-scars-to-retire is a countdown the player must see; dog-ear corners.
5. **Zero interaction states** — pickup/hover/snap/inspect for the game's primary touchable.
6. **No card back** — pack rip and face-down hand require it.
7. **Shop single flattens the card to a text row** — show the real card.
8. **Minislot doesn't inherit kind tint** — recipes should read by color.
9. Minor: `.worn` class → `.limited` (Meta's words); V2 flag overflows card bounds + uses a glyph; per-lane wear needs the context rule (§4C); negative aspect magnitudes need a shown exemplar.
