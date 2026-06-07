# Dynamic Content: the Tiered Dynamism Proposal (2026-06-05)

**Status: design proposal, post-research. Rulings at next review.**
Question: can runtime generation make Addendum roguelike-dynamic — brand logos, products, ad visuals per run?
Research: docs/research/ondevice-imagegen.md + ondevice-embeddings.md. Baseline: the layered art system (brands-and-products.md §4).

**The thesis:** the roguelike fantasy is real — but it is a function of *combinatorial space × naming × seeded identity × economy state*, not novel pixels. Balatro ships zero generated art. RimWorld ships zero generated art; its infinite-world feel comes from grammars over tags. Both feel endless. Tier 0 below IS that machine; the ML tiers are audited honestly against it.

---

## TIER 0 — No ML. Ships in v1. This is the roguelike engine.

### 0.1 Seeded brand identity (the character generator)
Each run's brand (or client roster, pending the §3 identity ruling) is a seeded draw from discrete, baked tables via a named PRNG substream (`rng.brand`): vertical → product tech-tree template → personality traits (3 of ~24: "thrifty", "loud", "heritage", "clinical"…) → audience priors → palette ID → mascot/person layer picks → voice adjectives feeding the grammar. All IDs and integers — sim-safe, deterministic, replayable from seed. Traits are mechanical hooks (audience priors, offer economics) AND flavor hooks (grammar inputs), so the name *means* something.

### 0.2 The naming grammar (concrete spec)
~10 KB of Lua data, `sim/namegen.lua`, pure function of (substream, vertical, traits). RimWorld-style: patterns over word banks, not pixels.

**Patterns** (weighted per vertical; weights shift by trait — "heritage" boosts `&`-pattern, "clinical" boosts constructed):
```
P1  {noun} & {noun}            -> "Hearth & Hew", "Loom & Letter"
P2  {noun} {abstract}          -> "Glow Theory", "Ember Works"
P3  {adj} {noun}               -> "Tidy Fox", "Plain Copper"
P4  {stem}{end}                -> "Lumina", "Verdane", "Sopely"   (constructed)
P5  {noun} {form}              -> "Cinder Supply Co.", "Petal Goods"
P6  The {noun} {form}          -> "The Whisk Society"
```
**Banks** (per vertical, 30–60 entries each; shared `abstract`/`form` banks):
- *skincare:* glow, dew, petal, bare, mist, balm, fern, tonic, rinse…
- *cookware:* hearth, ember, copper, whisk, rind, simmer, cast, grain…
- *software:* ledger, beacon, stack, pilot, relay, drafty, plot, kit…
- *apparel:* loom, hem, weft, marlow, selvage, oak, harbor, twill…
- *abstract:* Theory, Studio, Lab, Works, Club, House, Method, Index…
- *form:* Co., Goods, Supply, Society, Bros., & Sons…
- *constructed:* CV(C) syllable chaining from per-vertical phoneme banks (`lu-mi-na`), 2–3 syllables, vowel-ending bias for skincare, consonant-ending for software.

**Rules:** array indexing only (no `pairs()`); per-run uniqueness set; shipped blocklist of real-brand collisions and slurs (author-time screened — the banks are closed, so the *entire* reachable namespace is enumerable and lintable in CI, something no generative model can offer); locale layer per bank (the schema's string layer applies). Products reuse it: `{brand-stem} {product-noun} {variant}` → "Dew Cleanser No. 3". Ad flavor lines come from the same machinery over composed-ad tags (research doc §3c): "`{person.descriptor}` demos `{product.name}` in `{setting.descriptor}`".

### 0.3 The logo kit (the answer to "generate the brand's logo")
Diffusion's single worst failure mode is clean logos/wordmarks (imagegen doc §4). Combinatorics' single *best* case is exactly this — real identity systems are themselves combinatorial. Baked atoms: ~12 badge containers (circle, crest, lozenge…) × ~40 vertical-tagged motif glyphs (fern, whisk, beacon…) × brand palette × name set in 2–3 brand display fonts × ~6 layout templates = **tens of thousands of distinct, crisp, in-style, deterministic logos** rendered as layered sprites. Same trick for product labels and mascot accessories.

### 0.4 Combinatorial layered art + seeded palette variants
Already proposed (brands-and-products.md): setting × person × product alpha-cut layers = the ad's visual. Add seeded *palette-shift* variants: recolor shaders driven by **curated baked palettes selected by ID** — never free HSV rotation (that's how style mush happens without any ML). Plus decal slots (logo kit output composited onto product layers, packaging, desk props). A few hundred curated atoms yield combinatorial space ≫ what any player sees in 100 runs.

**Tier 0 cost:** ~0 bytes beyond planned art; ~10 KB Lua + banks. Fully deterministic, shared-seed screenshot-safe, one art style, all devices.

---

## TIER 1 — Embeddings: author-time only (research Config A). Adopt now.

Structural fact (embeddings doc §2): every image the game shows is baked, so both operands of every similarity are known at build time. Runtime embedder ships **nothing**. Two pipeline uses beat tags:

1. **Style-drift CI gate** — embed every new asset (CSD, CC-BY-4.0; pipeline-only) against the locked style centroid from the chosen exploration batch; fail the build past threshold. Gives the design-language ruling a machine check, like sign-invariance. Highest-value item in either research track.
2. **Baked int8 affinity tables + near-dup sets** — per-(layer, aspect) affinity scores (≈80 KB at 2k×40) replace binary tags with continuous matching, still argmax-over-integers in pure Lua; pairwise near-dup sets close ad-builder open question #5 (combination-fatigue echo penalty) as baked data, free. Plus CLIP-assisted tag *suggestion* (human-curated — the aspect taxonomy stays load-bearing pedagogy).

**Cost:** +0.1–2.5 MB data, zero runtime ML, bit-exact, sim-safe.
**Hard repo rules (propose for DECISIONS.md):** AMLR-licensed models (MobileCLIP etc.) banned from product *and* from generating shipped data; pipeline models MIT/Apache/CC-BY only. Determinism law extension: runtime ML output, if any ever ships, is presentation-only forever.

---

## TIER 2 — On-device diffusion: the honest verdict

**Not shippable in this game as designed. Not v1, not post-v1 as currently constrained.** The blockers are arithmetic, not taste:

- **Size:** smallest viable pipeline ≈ 600 MB–1 GB vs a 150 MB whole-app budget. ODR/PAD makes a 1 GB optional pack *legal*, not *right* — a $7.99 premium game gating its headline feature behind a post-purchase gigabyte betrays the budget's spirit.
- **Device floor:** 2023 mid-range Android = multi-minute CPU/GPU generations at full SoC load; MediaPipe imagegen is unmaintained; NPU paths are per-flagship-chipset. The 30-min no-throttle gate and repeated diffusion are mutually exclusive even on iPhones (Draw Things wiki, verbatim).
- **Style law:** 1–4-step distills trade away style fidelity; no runtime curation step; off-style outputs *will* ship to players. And the headline ask — logos — is the technology's canonical failure mode (Tier 0.3 wins it outright).
- **Determinism:** ANE/NNAPI floats aren't bit-stable across chips — same seed, different image per device. Shared-seed screenshot culture breaks.
- **License:** sd-turbo's Stability Community License is revocable with a $1 M revenue cliff a Balatro-scale hit blows through; SD 1.5/OpenRAIL-M is the only uncapped path.
- **Engineering:** 2–4 *weeks* of Obj-C/Core ML native plumbing (vs 2–4 days for haptics), Android a separate larger effort, for garnish.

**The parked scope, if ever revived — "Brand Lab" feature flag:** optional cosmetic ceremony at brand-creation and tech-tree unlocks; mascots/product-shots/scene art ONLY (never logos/wordmarks); fixed prompt templates, zero player free-text (keeps it developer-content, not UGC, for App Review); merged style-LoRA baked pre-conversion (Core ML supports merge-only — actually what we want); optional ODR/PAD pack; premium devices only; output presentation-only; TinyCLIP-8M vision-only mush-rejector per embeddings Config B (+13–16 MB).
**Revisit triggers (all must hold):** (a) a style-locked distill ≤100 MB total with an uncapped commercial license; (b) "3-year-old mid-range Android" means an NPU-class SoC with a maintained platform inference API; (c) a curation/QC story better than a 41%-IN-1k judge. Check yearly; do not pre-build.

---

## TIER APPLE — Image Playground / ImageCreator (iOS 18.4+)

Zero app-size, zero license cost, Apple-managed safety — the only free lunch. What it could do: player-customized client portraits, vanity mascots, office decor at ceremonies. Why it's parked anyway:
- **Style lock-in:** Apple's three house styles (animation/illustration/sketch) cannot express the locked chunky-cute retro-cartoon language; iOS 26's extra styles route through ChatGPT's *cloud* (violates local-first). Apple-styled art beside our authored art is definitional style mush.
- **Device gate:** Apple Intelligence hardware only (iPhone 15 Pro+) — excludes most of the installed base; `notSupported` must be a normal path, so it can only ever be garnish.
- **Android asymmetry:** no counterpart exists. An iOS-Pro-only visual feature forks the game's identity across platforms.
- **The real future hook:** iOS 27 reportedly adds third-party model support. If we can load **our own style-locked model** through Apple's free runtime at zero bundle cost, Tier 2's size blocker dies on iOS. That — not the house styles — is the trigger to re-open this tier (Android asymmetry still unsolved).

---

## THE AUDIT

| Constraint | Tier 0 (combinatorial) | Tier 1 (author-time embed) | Tier 2 (diffusion) | Tier Apple (ImageCreator) |
|---|---|---|---|---|
| Size ≤150 MB (target 100) | PASS (~0) | PASS (+0.1–2.5 MB data) | **FAIL** (600 MB–1 GB; ODR dodge betrays intent) | PASS (0 MB) |
| 3-yr mid-range Android floor | PASS | PASS (no runtime ML) | **FAIL** (minutes/gen, RAM, no NPU) | **FAIL** (no Android path at all) |
| 30-min no-throttle gate | PASS | PASS | **FAIL** (sustained SoC load throttles) | PASS (Apple-managed, one-shot) |
| Determinism / shared seeds | PASS (bit-exact) | PASS (baked integers, sim-safe) | **FAIL** (ANE floats vary per device) | FAIL (cloud-ish nondeterminism, per-device) |
| Style law (one style, no mush) | PASS (every atom curated) | PASS (it *enforces* the law) | **FAIL** (distills drift; no runtime curation) | **FAIL** (Apple's styles, not ours) |
| Local-first, no servers | PASS | PASS (CI only) | PASS (on-device) | PASS base / FAIL iOS-26 extra styles (ChatGPT cloud) |
| Premium positioning | PASS | PASS | FAIL (1 GB download, battery drain, device-gated headline) | WEAK (free, but garnish-only) |
| Android parity | PASS | PASS | FAIL (separate larger effort, flagship-only) | **FAIL** (structurally) |
| Commercial licensing | PASS | PASS (MIT/Apache/CC-BY pipeline rule) | RISKY (revocable / $1 M cliff; OpenRAIL only clean path) | PASS (platform API) |

---

## RECOMMENDATION

**NOW (v1):**
1. Build Tier 0 in full — it is not the consolation prize, it *is* the roguelike dynamism: seeded brand identities, the naming grammar (spec §0.2 → `sim/namegen.lua` + banks in `content/`), the logo kit, layered art with curated palette-shift variants. Add the name grammar + logo kit to the design-epic mock sweep so the fantasy is *visible* early.
2. Adopt Tier 1 / Config A in `tools/` CI: style-drift gate first (it protects the style ruling from day one of batch authoring), then affinity tables + near-dup sets when layer count justifies.
3. Record the two repo rules (AMLR ban; runtime-ML-is-presentation-only) in DECISIONS.md.

**NEXT (prototype):** a headless Lua harness that prints 200 seeded brands per vertical (name + traits + palette + logo-kit recipe) for author review — the cheapest possible test of whether the generated *identities* feel alive. Tune banks, not models.

**PARK (with triggers):** Tier 2 "Brand Lab" — revisit only when all three §Tier-2 triggers hold. Tier Apple — revisit at iOS 27 if third-party models land in Image Playground (the zero-size path to *our* style on iOS); Android asymmetry remains its open wound. Author-time generation (already planned) keeps feeding new curated layer atoms via Live Update data packs — the game stays "generative" exactly where curation exists.

The fantasy survives contact with the constraints — it just lives in seeds, grammars, and combinatorics, where Balatro's and RimWorld's always did.
