# Art direction & asset plan

> **⚠️ OVERRIDDEN 2026-06-05 (see DECISIONS.md):** the "Late-Night Cable" pixel/CRT direction below was rejected during design rounds 1–3. Current direction: **modern social-platform product UI** (TikTok/Meta vibe — near-black, clean grotesque type, rounded card tiles, aqua accent), cards-are-the-UI, sequenced settle-pass updates. Live reference: `design/mockups/account-screen.html`. This doc is retained for its asset-sourcing research; pixel-specific items (m6x11-class fonts, CRT shaders, 71×95 sprites) no longer apply as written.

Full sourcing research with links/licenses/prices: docs/research/assets.md.

## 1. Direction: "Late-Night Cable"

A master-control broadcast desk, not a poker table. Indigo base; phosphor magenta/cyan; amber warnings. Motifs: **ON AIR lamps** for live ads, **chyron lower-thirds** as metric tickers, **SMPTE bars** in empty ad slots, **VHS tracking noise** as the fatigue visual. The CRT shader is *diegetic* — you're literally watching monitors — which differentiates us from Balatro instead of borrowing its skin, and directly serves "watch your ad perform live."

- Reserve **"Terminal Floor"** (amber/green phosphor terminal) styling for deep-stats drill-in screens.
- Explicitly avoid green-felt casino set dressing. Casino lives in the *feel* (chip SFX, escalating dings, foil rarity), never the set.
- One master palette ≤64 colors (Lospec shortlist: Resurrect 64 / Apollo / SLSO8 subset), locked before any final art; indexed mode enforced in Aseprite.

## 2. Production conventions (Balatro's, adopted verbatim)

- `.aseprite` files are source of truth; Aseprite CLI exports `assets/1x/` + `assets/2x/` in CI.
- Card sprites in the **71×95 class** at 1x (69×93 visible + 1px pad), 142×190 at 2x — proven phone-readable. If cards need a metric strip, go *taller*, not denser.
- All juice = shaders + tweens on flat sprites; no baked animation frames. Shader key == filename == GLSL name.
- Edition shaders (foil/holo/polychrome-style) double as rarity/economy signals — visual treatment carries game meaning.
- Per-glyph animated text is a disproportionate share of perceived juice — engine support is budgeted (juice primitive #5).

## 3. Asset tiers

| Tier | Cost | Contents |
|---|---|---|
| **0 — Placeholder (now)** | ~$0–25 | Kenney Playing Cards (270 CC0) + Kenney Casino Audio (54 CC0 SFX: cards/chips/dice), m6x11 as temp font (attributed), ChipTone/jsfxr blips, moonshine-ported CRT chain / cards-fx-kit. Prove the loop feels good before art spend. |
| **1 — Owned identity (~vertical slice)** | ~$150–400 | 2–4 purchased fonts (Chevy Ray singles $5–10 or somepx $2–4: one chunky display, one dense UI, one tabular/mono for metrics), modular card-frame pack repainted, hand-made master card template at 1x/2x, locked palette. |
| **2 — Commission (post-validation)** | ~$1.5k–5k | Style bible first ($300–800), then batch-commissioned component icons ($20–60 each — the bulk of card content); painted hero art $75–85/card where warranted. Source: r/gameDevClassifieds, itch pack creators, pixel-art portfolios. |

**Hard rules:** never ship m6x11 (it's "the Balatro font") or anything from itch's "balatro" asset tag. AI tools (Retro Diffusion $65 — licensed training data) for author-time concepting/palette studies only; finals are hand-made or commissioned — the target audience is hostile to shipped AI art.

## 4. Audio

The LouisF/Balatro model: commission **one adaptive theme with intensity stems** (~$500–1.5k indie estimate), crossfaded by game state, odd meter encouraged — not a tracklist. SFX from Kenney casino packs + Sonniss GameAudioGDC archives (royalty-free, no attribution) + bespoke ChipTone blips. Rising-pitch tick chains and the global pitch-drop on failure are engine-side (docs/02-technical.md §3).
