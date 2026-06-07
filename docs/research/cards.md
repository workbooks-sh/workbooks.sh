# Card System Research — Addendum

**Track:** Cards (composition grammar, acquisition economy, content scale, generation pipeline, hidden-pattern system)
**Date:** 2026-06-05
**Status:** Research complete — opinionated recommendations included. Confidence levels flagged inline.

---

## TL;DR — The Opinionated Shape

- **Grammar:** Fixed function slots (Hook / Visual / Format / Offer) assembled into an Ad, played into an **Audience lane** (audience is the board, not a card). Every card carries **aspect tags** (Cultist Simulator's trick); resonance is computed from the *aggregated aspect vector*, not card identities. Modifiers ("charms") attach to proven ads as iterated creative.
- **Acquisition:** Premium-priced app, **zero real-money randomness**. All packs/shops use earned in-game currency only (Stacklands/Balatro loops). 4 rarity tiers at Balatro's 70/25/5/special shop weights. Duplicates auto-convert to "iteration points" that fuel upgrades.
- **Fatigue:** Per-card-**per-audience** wear, modeled on real frequency benchmarks (fatigue onset ~2.5 frequency cold, hook rate degrades first). Worn-out winners can be **archived into permanent account buffs** ("learnings") instead of dying uselessly.
- **Scale:** v1 ships **~130–160 cards** (≈38 hooks, 32 visuals, 12 formats, 20 offers, 24 modifiers, ~12 audience lanes, 6–10 clients). The learnable layer is a **~32-aspect taxonomy**, not the cards themselves.
- **Pipeline:** All cards are **data, authored at build time** (Lua tables compiled from a JSON/TOML source-of-truth, Cultist Simulator-style). AI assists flavor/art *at author time only*. A headless Monte-Carlo balance harness runs in CI.
- **Hidden patterns:** Two-layer resonance — a **global "truthy" layer** that never changes (so the game genuinely teaches advertising) plus a **per-run seeded layer** (Noita/NetHack precedent) that randomizes magnitudes and combo terms so wikis can't trivialize it. Feedback is **noisy and sample-size dependent** — reading noisy data IS the educational payload.

---

## 1. Composition Grammar — How Cards Become an Ad

### 1.1 Prior-art survey

**Cultist Simulator — verb + aspect slotting.** Cards are dragged into persistent Verb tiles; the recipe that fires is determined by the **combined aspects** on all slotted cards, not the specific cards ("The totals are all any recipe cares about, rather than what each specific card has" — community guides; confirmed by the wiki's Aspects/Actions pages). Aspects are typed numeric tags (Lantern 4, Moth 2…) and recipes are threshold matches against aggregated aspect totals. **This is the single most important mechanic to steal.** It decouples *content* (cards) from *rules* (recipes/resonance), which means you can add cards forever without touching the matching system, and players learn a *taxonomy* rather than memorizing card-pair lookup tables.
Sources: [Cultist Simulator Wiki — Aspects](https://cultistsimulator.fandom.com/wiki/Category:Aspects), [Actions](https://cultistsimulator.fandom.com/wiki/Actions), [Rites Done Right guide](https://steamcommunity.com/sharedfiles/filedetails/?id=1429378632).

**Stacklands — physical stacking + discoverable recipes.** Cards stack on a spatial board; "Idea" cards act as visible recipes (2 Wood + 1 Stone + Villager = House); the core loop is *sell resources → buy card packs*. The free-stacking grammar is wrong for us (too fiddly for precise composition on a phone, unbounded combinatorics to balance), but two things transfer: (a) **recipes as collectible knowledge** — discovering "what combines" is itself a reward; (b) **packs bought with earned currency as the core compulsion loop** — pack-ripping juice without real money.
Sources: [Game Developer on Stacklands' simplicity](https://www.gamedeveloper.com/business/how-stacklands-uses-simplicity-to-create-a-compelling-card-based-village-builder), [Pixelated Playgrounds design analysis](https://www.pixelatedplaygrounds.com/sidequests/game-design-perspective-stacklands).

**Slay the Spire / Balatro — deck identity.** In StS your deck *is* your strategy; Balatro layers a persistent tableau (jokers) over a stream of transient plays (hands). The transferable insight: separate **persistent account-level modifiers** (your "agency": team, tools, brand assets — joker-like) from **per-play composition** (the ad — hand-like). Balatro's loop works because every shop visit mutates the persistent layer while every hand exercises it. Our equivalent: the *account tableau* shapes how every ad scores; the *ad composition* is the moment-to-moment play.
Sources: [Balatro Wiki — Jokers](https://balatrowiki.org/w/Jokers), [PC Gamer on the 120→150 joker story](https://www.pcgamer.com/games/card-games/balatro-was-only-supposed-to-have-120-jokers-but-instead-of-correcting-a-publisher-mistake-localthunk-just-made-30-more-of-them/), [StS card design](https://slaythespire.wiki.gg/wiki/Cards).

**Reigns — radical simplicity.** One card, two swipes, four hidden meters; "the game purposely hides its complexity behind the simplicity of swiping" ([Game Developer deep dive](https://www.gamedeveloper.com/design/game-design-deep-dive-creating-an-adaptive-narrative-in-i-reigns-i-)). The lesson is **per-decision cognitive load**: on mobile, each individual interaction must be near-trivial even if the system is deep. Composition should feel like 3–4 quick snaps, not deck-construction homework.

**Wildfrost charms / Inscryption sigils — modifiers on base cards.** Wildfrost charms are attachable trinkets, **max 3 per card** ([Wildfrost Wiki — Charms](https://wildfrostwiki.com/Charms)); Inscryption has **79 sigils** with per-sigil power levels (−3…+5) used for internal balance accounting ([Inscryption Wiki — Sigils](https://inscryption.fandom.com/wiki/Sigils)). This is the right model for **"iterated creative"**: you don't replace a winning ad, you *iterate* it — attach a modifier (new hook variant, captions, UGC re-cut) that mutates its stats. The 3-attachment cap and per-modifier power budgets are proven guardrails.

### 1.2 Which grammar fits `Hook + Visual + Format + Offer + Audience = Ad`?

**Recommendation: fixed function slots + aspect aggregation + attachable modifiers.** (Confidence: high)

- **Fixed slots, not free stacking.** An ad *genuinely has* these components — the slot structure is itself the lesson. Real creative-strategy frameworks decompose exactly this way: "angle decides the argument, hook delivers the entry point, claim pays it off, format shapes attention, CTA closes" ([adlibrary.com on creative angles](https://adlibrary.com/posts/creative-angle)). Fixed slots bound the combinatorics (balanceable), read instantly on a phone, and make every choice a Reigns-sized micro-decision.
- **Aspects, not card-ID matching.** Every card carries 2–4 aspect tags with magnitudes (e.g., a hook card: `urgency 2, social_proof 1`). The composed ad's aspect vector = sum of slotted cards' aspects (+ modifier deltas). Resonance is computed vector-vs-audience, Cultist Simulator-style. Players learn "this audience responds to curiosity + authenticity," not "card #47 beats lane #3."
- **Modifiers (charms) for iteration.** Cap at 3 per ad. Modifiers are how a proven winner becomes a foil/holo "V2."

**Strong opinion: Audience is NOT a slot in the ad.** (Confidence: medium-high)
Pull Audience out of the composition and make it the **lane you deploy into** (a campaign/ad-set row on the live board). Reasons:
1. **Truthy:** in real paid media, creative and targeting are different layers of the stack (campaign → ad set → ad). Conflating them teaches the wrong mental model.
2. **Legibility:** the hidden-pattern game becomes "ad attribute vector × audience lane," which is visually mappable (rows = audiences, plays = ads). Pattern learning needs a stable axis to learn *against*.
3. **Slot budget:** 4 slots is already a lot of taps. Reigns says go smaller.

Similarly, **Offer should be partially supply-constrained by the client** (the client grants you offer cards — "20% off," "free shipping," "bundle"), which is truthy (you don't invent the client's discount) and creates scarcity gameplay.

**Final grammar:**

```
AD  = [Hook] + [Visual] + [Format] + [Offer]      (4 slots; early game starts with 2)
       + up to 3 [Modifier] attachments (iteration)
PLAY = AD → deployed into an [Audience] lane, funded with [Budget]
SCORE = resonance( Σ aspects(AD), hidden_vector(Audience), metric ) per metric, over time, with noise
```

**Onboarding ramp:** start runs/accounts with only Hook + Visual slots live (Format locked to "Static Image," Offer locked to client default). Unlock Format slot at account level 2, Offer slot at level 3, modifiers at level 4. This is the StS/Balatro unlock curve applied to *grammar complexity itself*. (Confidence: medium — needs playtesting.)

---

## 2. Acquisition Economy

### 2.1 The regulatory and ethical frame (verified current, June 2026)

This game should ship with **zero real-money randomized purchases**. This is both an ethics call and a hard practical one:

- **Apple App Store Guideline 3.1.1** requires disclosing odds for any paid loot-box mechanic ([National Law Review](https://natlawreview.com/article/apple-requires-disclosure-odds-loot-boxes), [Game Developer](https://www.gamedeveloper.com/business/guideline-changes-mean-app-store-devs-must-now-reveal-loot-crate-odds)).
- The 2026 landscape is tightening sharply: **Brazil bans loot boxes for minors starting 2026; Australia rates paid chance mechanics 15+ minimum; Germany's Bundesrat is pushing toward 18+/gambling treatment** ([2026 gaming law roundup](https://completeaitraining.com/news/2026-gaming-law-ai-lawsuits-child-safety-loot-boxes-and-a/), [Wikipedia: microtransaction regulation](https://en.wikipedia.org/wiki/Regulations_protecting_consumers_from_microtransactions)). US FTC attention is on undisclosed odds and minors' access ([Gamma Law](https://gammalaw.com/how-does-us-consumer-protection-law-apply-to-video-game-loot-boxes-and-gacha-mechanics/)).
- **Ratings risk is real even without money:** Balatro and Luck Be a Landlord were both initially rated **PEGI 18 for "prominent gambling imagery"** despite having no microtransactions; both were reduced to **PEGI 12 on appeal** (Feb 2025), and PEGI is building more granular gambling-theme criteria ([PEGI official](https://pegi.info/news/pegi-complaints-board-amends-classifications-balatro-and-luck-be-landlord-pegi-12), [TechRadar](https://www.techradar.com/gaming/balatro-has-had-its-pegi-18-age-rating-overturned-following-appeal-i-hope-this-change-will-allow-developers-to-create-without-being-unfairly-punished)). A casino-energy game about *advertising* that also sold gacha would be radioactive — and would poison the educational positioning.
- **The premium model demonstrably works at our exact reference point:** Balatro — $14.99 PC / $9.99 mobile + Apple Arcade (Balatro+) — passed 5M copies by Jan 2025, roughly half after the Sept 2024 mobile launch; mobile grossed $1M in week one ([Wikipedia](https://en.wikipedia.org/wiki/Balatro)). Luck Be a Landlord ships premium on iOS/Android too ([App Store](https://apps.apple.com/us/app/luck-be-a-landlord/id6450724928)).

**Recommendation:** premium ($7.99–9.99) or Apple Arcade-style deal. All randomness is earned-currency only. (Confidence: high)

**The anti-example to study:** Marvel Snap's acquisition economy (Collection Level → Spotlight Caches → Snap Packs) generated continuous community backlash — token income cuts, opaque pity systems, three full redesigns in three years ([Naavik analysis](https://naavik.co/digest/marvel-snap-card-acquisition-spotlight-caches/), [Marvel Snap Zone on Snap Packs](https://marvelsnapzone.com/snap-packs-announcement/), [Dexerto on the backlash](https://www.dexerto.com/marvel-snap/marvel-snap-players-frustrated-with-collectors-token-change-2209729/)). Monetized card acquisition turns your collection system into a permanent PR problem.

### 2.2 In-game acquisition channels

Keep the *gacha feel* (pack-ripping is genuinely juicy) but fuel it entirely with earned soft currency. Channels, in priority order:

1. **The Shop (between "days"/milestones).** Balatro's structure is the template: ~2 single cards + 2 packs + 1 voucher-like permanent upgrade per visit, with rerolls costing escalating cash ([Balatro Wiki — The Shop](https://balatrowiki.org/w/The_Shop)). Crucially, Balatro's **interest mechanic** (save money → earn interest, capped) creates the buy-now-vs-compound tension; our version is truthy for free: **money spent on cards is money not spent on media budget** — the real creative-vs-spend tradeoff every ad account faces.
2. **Client unlocks.** Signing a new client vertical (skincare, fitness app, DTC cookware — per the demo-brands guidance, model these on mid-tier DTC archetypes) unlocks that vertical's themed sub-pool of offers/visuals + 1–2 signature cards. This is Balatro's deck-unlock loop wearing a business suit.
3. **Account level-ups.** Deterministic, choice-of-3 (StS card-reward style) — guarantees pattern-relevant cards reach the player even with bad shop luck.
4. **Packs.** 3–5 cards, one guaranteed at-or-above-uncommon, **odds printed on the pack** (good practice even when free; trains the real skill of expected-value thinking).

### 2.3 Rarity, duplicates, upgrades

- **Rarity tiers:** 4, with Balatro's verified shop weights — **Common 70% / Uncommon 25% / Rare 5% / Legendary excluded from shops** (Balatro's 5 legendaries only appear via The Soul spectral card, 0.3% in packs — a great "white whale" pattern: [Balatro Wiki — Jokers](https://balatrowiki.org/w/Jokers)). Rarity should track *effect complexity and build-around-ness*, not raw power (Balatro/StS rule: rares warp your strategy, commons grease it).
- **Duplicates → Iteration Points.** Dupes auto-convert into the upgrade currency. Thematically perfect: a duplicate creative concept is *fodder for iteration*. No dead pulls, no dupe rage (the #1 Snap complaint).
- **Upgrading proven winners = foil/holo as "iterated creative."** Spend Iteration Points + a fatigued copy of the card to mint a **V2**: visually foiled, slightly mutated aspect vector (e.g., +1 to its strongest aspect, −fatigue rate, or a new modifier socket). Cap modifier sockets at 3 (Wildfrost's proven ceiling). The mutation matters: iterating a winner in real life *changes what resonates* — V2 is not strictly better, it's *different and fresher*, which keeps the pattern game alive. (Confidence: medium-high)

### 2.4 Fatigue as per-card wear

Ground it in the real numbers (verified benchmarks, 2026):

- Real-world fatigue onset: **frequency ~2.5 for cold audiences, 4–6 for retargeting**; **hook rate degrades first**, then hold rate, then CTR — the offer wears out last ([AdAmigo frequency benchmarks](https://www.adamigo.ai/blog/meta-ads-frequency-benchmarks-when-ads-start-fatiguing), [adlibrary hold-rate](https://adlibrary.com/posts/hold-rate), [Koro hook→hold guide](https://getkoro.app/blog/koro-hook-rate-to-hold-rate)).

**Design:** fatigue is a per-card **per-audience** wear meter that fills with impressions delivered into that lane. As it fills: thumbstop penalty first, then hold, then CTR — staged exactly like reality, which means the player literally learns the real degradation signature. Wear **regenerates slowly** while the card rests (audiences forget), but each full fatigue cycle leaves a small permanent scar (max-freshness loss). After ~3 cycles a card is "worn out" and can be:
- **Retired → Archived as a Learning:** converts to a small permanent account buff or a recipe hint ("urgency hooks fatigue 20% faster on Gen Z lanes — noted"). Loss becomes progression. (Confidence: medium — the archive-buff needs balancing care, but the *shape* is right: never let a beloved winner just evaporate, Balatro's eternal-joker attachment shows how much players bond with specific cards.)
- **Recycled into Iteration Points** to mint its V2.

---

## 3. Content Scale for v1

### 3.1 Anchors from shipped games (verified)

| Game | Core collectible count | Notes |
|---|---|---|
| Balatro | **150 jokers** (61C/64U/20R/5L) + 22 tarots + 12 planets + 18 spectrals + 32 vouchers | 105 available at start, 45 unlockable ([wiki](https://balatrowiki.org/w/Jokers)); the 150 number was famously a publisher miscommunication LocalThunk just rolled with ([PC Gamer](https://www.pcgamer.com/games/card-games/balatro-was-only-supposed-to-have-120-jokers-but-instead-of-correcting-a-publisher-mistake-localthunk-just-made-30-more-of-them/)) |
| Slay the Spire | **~75 cards per character** | Explicit MegaCrit design target: more made drafting "haphazard" ([Wikipedia](https://en.wikipedia.org/wiki/Slay_the_Spire)) |
| Luck Be a Landlord | **152 symbols + 227 items** | Solo dev, Godot ([Wikipedia](https://en.wikipedia.org/wiki/Luck_Be_a_Landlord)) |
| Inscryption | **79 sigils** across the whole game | Sigils carry internal power-level budgets ([wiki](https://inscryption.fandom.com/wiki/Sigils)) |
| Cultist Simulator | ~10 verbs, dozens of aspects, hundreds of element cards | Depth lives in the aspect taxonomy, not card count |

### 3.2 The combinatorics argument

Slot grammars multiply, they don't add. With pools of 38 hooks × 32 visuals × 12 formats × 20 offers, the raw composition space is **~292,000 distinct ads** before modifiers — against ~12 audience lanes that's 3.5M (ad, lane) pairs. Card count is *not* the depth bottleneck; **aspect-taxonomy size is**. The learnable layer should be **~32 aspects across 5–6 axes** (emotional register, persuasion mechanism, production style, tone, value frame, urgency), because that's what players actually memorize and reason over — and ~30 concepts is roughly what a genuine creative-strategy curriculum teaches (compare the angle/hook/claim/format/CTA decomposition working strategists use: [adlibrary](https://adlibrary.com/posts/creative-angle), [Pilothouse 3-3-3 testing framework](https://www.pilothouse.co/post/meta-creative-testing-framework-the-3-3-3-approach-to-finding-winners)).

### 3.3 v1 budget (recommendation, confidence: medium-high)

| Type | Count | Reasoning |
|---|---|---|
| Hook cards | 36–40 | Highest-variance slot in reality (hook rate is the first metric to move); needs the widest pool |
| Visual style cards | 30–34 | Second expressive axis; pairs with hooks for thumbstop combos |
| Format cards | 10–12 | Reality has ~a dozen that matter (static, carousel, UGC video, talking head, demo, meme, testimonial…); small pool keeps it learnable |
| Offer cards | 18–22 | Client-granted; scarcity is the point |
| Modifiers (charms) | 22–26 | Iteration verbs: re-cut, captions, new thumbnail, social proof overlay… |
| **Total playing cards** | **~130–160** | Balatro-sized; ~60% available from start, ~40% unlockable |
| Audience lanes | 10–12 | Hidden vectors; 3–4 active per run |
| Clients | 6–10 | Run-defining, Balatro-deck-like |

Below ~110 total, shop variety starves and patterns brute-force too fast; above ~180, art/balance cost balloons and per-card distinctiveness collapses on a phone screen (every card must be readable at thumbnail size). Plan post-launch packs in +20–30 card increments per new client vertical.

---

## 4. Generation Pipeline (build-time, never runtime)

### 4.1 Precedents for cards-as-data

- **Cultist Simulator:** essentially the entire game is **plain JSON content files** (elements, recipes, verbs, decks, legacies) loaded by the engine; the modding system is just "drop more JSON in a folder" ([Weather Factory modding docs](https://weatherfactory.biz/modding/), [CS wiki — Modding](https://cultistsimulator.fandom.com/wiki/Modding)). One file = one entity type. This is the gold standard for content/engine separation.
- **Balatro:** programmed in **Lua on the LÖVE framework** ([Wikipedia](https://en.wikipedia.org/wiki/Balatro)); jokers are Lua tables, and the Steamodded modding framework's `SMODS.Joker` shows the mature shape of a card record: `key`, `loc_txt`, `config`, `rarity` (1=Common…4=Legendary), `cost`, `atlas`, `pos`, plus a `calculate(self, card, context)` hook for behavior ([Steamodded wiki](https://github.com/Steamodded/smods/wiki/SMODS.Joker)).

**Recommendation:** author in **JSON/TOML as the source of truth** (toolable, diffable, validates in CI), **compile to Lua tables at build time** if the engine is Lua (or load JSON directly otherwise). Keep behavior out of data: cards reference *named effect hooks*; only modifiers/legendaries get bespoke script. (Confidence: high)

### 4.2 Pipeline stages

```
authoring/
  aspects.toml          # the taxonomy: ~32 aspects, axes, descriptions, teaching notes
  archetypes/*.toml     # hand-authored card archetypes + combinatorial expansion specs
  clients.toml          # client/vertical definitions, offer grants
  audiences.toml        # audience archetype PRIORS (not the hidden vectors — see §5)

tools/
  expand.py|ts          # 1. combinatorial expansion: archetype × attribute grammar → candidate cards
  curate/               # 2. human pass: kill near-duplicates, rename, tune aspect vectors
  flavor_gen.ts         # 3. AI-assisted flavor text + art prompts (AUTHOR TIME ONLY)
  balance_sim.ts        # 4. headless Monte-Carlo: N simulated runs vs sampled audience vectors
  lint.ts               # 5. schema validation + distinctiveness lint + loc key check
  bake.ts               # 6. emit content pack: cards.lua / cards.json + sprite atlas

content/                # baked, shipped inside the app bundle (local-first, no server)
  cards.json  atlas.png  audiences.json  clients.json
```

1. **Hand-authored templates + combinatorial attributes.** An archetype like `hook/urgency_countdown` declares variable attributes (`tone: deadpan|breathless|smug`, `target_metric_bias`, rarity band) and the expander emits 2–4 candidate cards per archetype. ~60 archetypes → ~180 candidates → curate down to ~140. Combinatorial generation gives coverage of the aspect space; curation gives soul.
2. **Aspect-vector coverage check:** the linter asserts every aspect appears on ≥6 cards across ≥2 slot types, and no two same-slot cards within edit distance 1 of the same aspect vector at the same rarity (anti-bloat rule).
3. **AI assistance is an authoring tool only.** Flavor text drafts, art-prompt drafts, name brainstorms — all at build time, human-approved, baked into the bundle. No runtime generation: deterministic content is required for the seeded-pattern system (§5), for App Store predictability, and for local-first (no server). For art direction, prefer a **stylized icon/glyph system** over realistic ad mockups — cheaper, more readable at card size, and dodges the "fake brand" uncanny valley entirely.
4. **Balance harness:** simulate thousands of greedy/random/learning agents against sampled audience vectors; flag dominant cards (win-rate delta > threshold), dead cards (<2% pick value), and degenerate combos. Balatro-scale balance with 150 interacting pieces is only tractable with simulation; LBaL's 152+227 economy was solo-dev-maintained the same way (inference; confidence: medium).

### 4.3 Card schema sketch

JSON source of truth (one card):

```json
{
  "id": "hook_countdown_v1",
  "slot": "hook",
  "name": "Only 6 Left",
  "flavor": "Nothing focuses the mind like a number going down.",
  "rarity": "uncommon",
  "cost": 4,
  "art": { "atlas": "hooks", "pos": [3, 1] },
  "aspects": { "urgency": 3, "scarcity": 2, "trust": -1 },
  "base": { "thumbstop": 0.8, "hold": 0.1, "ctr": 0.5, "cvr": 0.2 },
  "fatigue": { "wear_rate": 1.35, "recovery": 0.6, "max_cycles": 3 },
  "synergy_tags": ["countdown", "number_led"],
  "requires": { "format_any": ["static", "story", "ugc_video"] },
  "unlock": { "type": "client_milestone", "client": "dtc_apparel", "tier": 2 },
  "upgrade": { "to": "hook_countdown_v2", "iteration_points": 12 },
  "teach": "Urgency hooks spike thumbstop and CTR but fatigue ~35% faster and erode trust with repeat exposure."
}
```

Baked Lua (engine-facing, compiled by `bake.ts`):

```lua
CARDS.hook_countdown_v1 = {
  slot = "hook", rarity = 2, cost = 4,
  aspects = { urgency = 3, scarcity = 2, trust = -1 },
  base = { thumbstop = 0.8, hold = 0.1, ctr = 0.5, cvr = 0.2 },
  fatigue = { wear_rate = 1.35, recovery = 0.6, max_cycles = 3 },
  synergy = { "countdown", "number_led" },
  requires = { format_any = { "static", "story", "ugc_video" } },
  -- behavior by reference, not inline code:
  effects = { "fx_urgency_decay_bonus" },
  loc = "hook_countdown_v1",  -- name/flavor/teach live in loc files
}
```

Notes: `teach` strings power an optional "strategist's notebook" — the go-deeper educational layer. `rarity` as string in source, int in bake (Steamodded convention: 1–4). Localization keys split out at bake time (Cultist Simulator's one-entity-type-per-file rule is worth adopting for authoring sanity).

---

## 5. The Hidden-Pattern System

### 5.1 Core model

Each audience lane holds a hidden **resonance profile**: per-metric weight vectors over aspect space plus a sparse set of nonlinear **combo terms**:

```
thumbstop(ad, aud) = σ( W_aud_ts · aspects(ad) + Σ combo_ts(aᵢ, aⱼ) + format_affinity ) + noise
```

with separate weights per metric, staged truthy structure (hook/visual aspects dominate thumbstop; offer/value aspects dominate CTR/CVR; audience-offer fit dominates ROAS), and **fatigue acting on the observation, not the truth** (the pattern is still there; the audience is just numb to this card).

### 5.2 Learnable but not memorizable: the two-layer split (the key design decision)

**Layer 1 — Global truths (never randomized).** The *signs* and rough orderings of effects are fixed across all players and all runs, and they encode real advertising knowledge: urgency lifts CTR but accelerates fatigue and erodes trust; UGC formats lift thumbstop with novelty-seeking audiences; offer strength dominates conversion; frequency past ~2.5 starts decay; hook rate degrades before CTR ([AdAmigo](https://www.adamigo.ai/blog/meta-ads-frequency-benchmarks-when-ads-start-fatiguing), [adlibrary](https://adlibrary.com/posts/creative-angle), [Motion on creative metrics](https://motionapp.com/blog/key-creative-performance-metrics)). **This layer is the curriculum.** If it were randomized the game would teach nothing.

**Layer 2 — Seeded instance variation (per run / per client).** *Magnitudes*, audience-specific quirks, and the sparse combo terms are drawn from archetype priors using the run seed. Precedents prove this exact pattern works:
- **Noita's Lively Concoction / Alchemic Precursor:** recipes "randomized for every seed… generated from three randomly selected powders and liquids" — a per-seed hidden recipe the community can only crack per-seed, with seed-calculators as meta-tooling ([Noita wiki](https://noita.wiki.gg/wiki/Alchemy), [generator implementation](https://github.com/kbjr/noita-recipes)).
- **NetHack's identification game:** item appearances "randomly shuffled at game start," so knowledge transfers as *method* (how to test safely) not *lookup table* ([NetHack wiki — Randomized appearance](https://nethackwiki.com/wiki/Randomized_appearance), [Identification](https://nethackwiki.com/wiki/Identification)). That's precisely the skill transfer we want: the wiki can teach you *how to run a test matrix*, not *the answer*.
- **Balatro/StS seed infrastructure:** deterministic seeded queues, shareable seeds, daily climbs ([Balatro wiki — Seed](https://balatrowiki.org/w/Seed), StS Daily Climb). Determinism per seed enables daily challenges ("everyone gets the same mystery audience today — compare ROAS") which is both community fuel and an anti-cheese device (seeded runs excluded from progression, as both games do).

**Partial randomization rule (be precise here):** randomize *within priors* — e.g., "Gen Z skincare" lanes always like authenticity (sign fixed, global), but whether *this run's* instance is authenticity 0.4 or 0.9, and whether it carries the `meme×self_aware` combo bonus, is seeded. Never flip signs of Layer-1 truths; never seed-randomize fatigue mechanics. (Confidence: high on the architecture; medium on the exact prior widths — tune in playtest.)

### 5.3 Noise is the pedagogy

Observations come through finite impressions: early reads on a new ad are small-sample and noisy; confidence tightens with spend. Show this honestly (shaded bands that narrow, "needs ~2k more impressions to call it"). The core expert skill of a media buyer — *not overreacting to small samples, killing losers fast, scaling winners with discipline* — falls directly out of noisy-feedback design. The 3-3-3-style isolate-one-variable testing workflow ([Pilothouse](https://www.pilothouse.co/post/meta-creative-testing-framework-the-3-3-3-approach-to-finding-winners)) becomes the literal optimal strategy, which means playing well *is* practicing the real method.

**Anti-frustration valves:** (a) "Insight" consumables that reveal one audience weight (the Cultist Simulator hint-economy move); (b) the archived-learnings notebook auto-records confirmed patterns ("✓ urgency hooks fatigue fast on Lane 3"); (c) audience **drift** — a slow seeded random walk per season — keeps long accounts from solving into stasis and models real market shift. (Confidence: medium)

---

## Open questions for the design track

1. Real-time loop pressure: how many simultaneous live lanes can a player monitor on a phone? (Affects audience-lane count and fatigue pacing more than card count.)
2. Does Offer-as-client-granted feel scarce-fun or scarce-annoying? Prototype both.
3. Modifier acquisition: shop-bought vs crafted-from-dupes vs earned-from-milestones — recommend crafted-from-dupes first for economy simplicity.
4. Whether V2/foil cards should ever be strictly better (proposal says no — "different and fresher" — but compulsion-loop pull toward strictly-better is strong; playtest).
5. Aspect taxonomy authorship needs a real creative strategist's review pass — the 5–6 axes proposed here are synthesized from practitioner content, not validated by one.

## Sources

- https://balatrowiki.org/w/Jokers — joker counts (150; 61/64/20/5), shop rarity weights 70/25/5, Soul-card legendary acquisition
- https://balatrowiki.org/w/The_Shop — shop slot structure, rerolls
- https://balatrowiki.org/w/Seed — seeded-run determinism and queues
- https://www.pcgamer.com/games/card-games/balatro-was-only-supposed-to-have-120-jokers-but-instead-of-correcting-a-publisher-mistake-localthunk-just-made-30-more-of-them/ — 120→150 jokers anecdote
- https://en.wikipedia.org/wiki/Balatro — Lua/LÖVE, sales, mobile pricing/Apple Arcade
- https://en.wikipedia.org/wiki/Slay_the_Spire — ~75 cards/character design target
- https://slaythespire.wiki.gg/wiki/Cards — card structure
- https://en.wikipedia.org/wiki/Luck_Be_a_Landlord and https://apps.apple.com/us/app/luck-be-a-landlord/id6450724928 — 152 symbols/227 items, premium mobile
- https://cultistsimulator.fandom.com/wiki/Category:Aspects, https://cultistsimulator.fandom.com/wiki/Actions, https://steamcommunity.com/sharedfiles/filedetails/?id=1429378632 — verb/aspect/recipe matching
- https://weatherfactory.biz/modding/, https://cultistsimulator.fandom.com/wiki/Modding — JSON data-driven content
- https://www.gamedeveloper.com/business/how-stacklands-uses-simplicity-to-create-a-compelling-card-based-village-builder, https://www.pixelatedplaygrounds.com/sidequests/game-design-perspective-stacklands — Stacklands stacking/idea-recipes/pack loop
- https://www.gamedeveloper.com/design/game-design-deep-dive-creating-an-adaptive-narrative-in-i-reigns-i- — Reigns swipe design
- https://wildfrostwiki.com/Charms — charms, 3-per-card cap
- https://inscryption.fandom.com/wiki/Sigils — 79 sigils, power levels
- https://github.com/Steamodded/smods/wiki/SMODS.Joker — Lua card schema precedent, rarity int mapping
- https://natlawreview.com/article/apple-requires-disclosure-odds-loot-boxes, https://www.gamedeveloper.com/business/guideline-changes-mean-app-store-devs-must-now-reveal-loot-crate-odds — Apple 3.1.1 odds disclosure
- https://completeaitraining.com/news/2026-gaming-law-ai-lawsuits-child-safety-loot-boxes-and-a/, https://en.wikipedia.org/wiki/Regulations_protecting_consumers_from_microtransactions, https://gammalaw.com/how-does-us-consumer-protection-law-apply-to-video-game-loot-boxes-and-gacha-mechanics/ — 2026 loot-box regulatory landscape (Brazil, Australia, Germany, FTC)
- https://pegi.info/news/pegi-complaints-board-amends-classifications-balatro-and-luck-be-landlord-pegi-12, https://www.techradar.com/gaming/balatro-has-had-its-pegi-18-age-rating-overturned-following-appeal-i-hope-this-change-will-allow-developers-to-create-without-being-unfairly-punished — PEGI gambling-imagery ratings saga
- https://naavik.co/digest/marvel-snap-card-acquisition-spotlight-caches/, https://marvelsnapzone.com/snap-packs-announcement/, https://www.dexerto.com/marvel-snap/marvel-snap-players-frustrated-with-collectors-token-change-2209729/ — Snap acquisition-economy cautionary tale
- https://www.adamigo.ai/blog/meta-ads-frequency-benchmarks-when-ads-start-fatiguing — fatigue frequency benchmarks (2.5 cold / 4–6 retargeting), degradation order
- https://adlibrary.com/posts/hold-rate, https://getkoro.app/blog/koro-hook-rate-to-hold-rate, https://www.adsights.ai/resources/glossary/metrics/thumbstop-rate-tsr, https://admanage.ai/blog/what-is-a-good-hook-rate-for-facebook-ads — hook/thumbstop/hold definitions and 2026 benchmarks
- https://adlibrary.com/posts/creative-angle, https://www.pilothouse.co/post/meta-creative-testing-framework-the-3-3-3-approach-to-finding-winners, https://motionapp.com/blog/key-creative-performance-metrics — creative-strategy taxonomy (angle/hook/claim/format/CTA), testing frameworks
- https://noita.wiki.gg/wiki/Alchemy, https://noita.fandom.com/wiki/Lively_Concoction, https://github.com/kbjr/noita-recipes — per-seed hidden recipes
- https://nethackwiki.com/wiki/Randomized_appearance, https://nethackwiki.com/wiki/Identification — per-game identification randomization
