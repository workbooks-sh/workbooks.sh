# Decision log

Format: date · decision · rationale · status. Reversals get a new entry, never an edit.

## 2026-06-06 — Naming: AdBuy

The project is named **AdBuy** — one word, title case. "Ad" as in advertisement,
not addition. Supersedes both prior names: "Addendum" (original working title)
and "Add-By" / "add-by-ad-buy" (import slug). The in-tree rename (dir, display
name, manifest, bundle-id slug) happened on this date. Trademark/ASO search
targets "AdBuy". The ON AIR phrase remains unsearched.

## 2026-06-05 — Engine: Defold

Lua-native (LuaJIT), editor-direct signed IPA/AAB bundling from macOS, hot reload of code/art/shaders **on a physical phone**, tiny binaries, monthly releases, foundation-owned. Survived two adversarial skeptic passes (shipping reality; capability gaps) at high confidence — including verification that its sound component supports runtime pitch/speed ramping (Balatro-style audio juice) and that it beat Apple's Xcode 26 upload mandate by ~3 months.

- **Runner-up:** LÖVE — Balatro lineage and maximal composability, but LÖVE 12 still unreleased (stable = 11.5, Dec 2023, deprecated GL on iOS), DIY Xcode/Gradle ownership, iOS haptics require a hand-written Obj-C bridge. Documented fallback if Defold's message-passing structure proves intolerable after the Phase 0 spike; budget +2–4 weeks.
- **Escape hatch:** Godot 4.6 — only if the Lua requirement softens (means GDScript in practice).
- **Eliminated:** Solar2D (bus factor 1), Unity (no decisive advantage, pricing whiplash).
- **Known costs accepted:** haptics native extension is a week-one task (2–4 days); SDF/bitmap text only (fine for numbers/labels); watch defold#8571 (iOS touch-drag frame stutter — the Phase 0 spike will surface it).

Full analysis: docs/research/engine.md; the adversarial-pass specifics (Defold sound speed range, Xcode 26 timeline, defold#8571) are recorded in docs/research/engine-verification.md. Architecture rule that keeps the choice cheap to reverse: **the entire simulation lives in plain framework-free Lua modules; Defold is only the presentation shell.**

## 2026-06-05 — Core loop: Campaign Sprint Waves (hybrid), tuned game-first

Judge panel split 2–1 (compulsion + feasibility → run-based; pedagogy → hybrid-waves). **Author ruled: hybrid-waves.** Its Build → Flight → Autopsy → Shop wave structure is the locked skeleton; the run-based and live-desk designs are kept as reference (docs/design/).

Because the identity tiebreaker is *game first* (below), the compulsion judge's critiques of hybrid-waves are treated as mandatory fixes, not suggestions: tighter waves (median ≤6 min vs the skeleton's 6.5-min median / ~8-min boss ceiling), per-sim-day chyron stingers, higher in-flight verb density, 15-second skimmable autopsies with depth on tap, sharper dollar-curve escalation legibility, and a shorter default engagement. Full synthesized spec: docs/01-game-design.md.

## 2026-06-05 — Identity tiebreaker: game first

When pedagogy machinery conflicts with loop tightness, the loop wins. Pedagogy remains load-bearing (real metric names, truthful Layer-1 patterns, graded hypothesis pins) but is delivered in formats that never brake momentum. Practical consequences: autopsies skim in 15s; the diagnosis engine ships as a 6-case rule table in v1, not a prose engine; process-grading of trust pips ships in its simplest form; effect-size prediction bands and Playbook/Standing Orders are post-v1.

## 2026-06-05 — Platform: mobile-first, mobile-only

No desktop demo. iOS leads (TestFlight is the playtest surface), Android close behind via Defold's dual bundling. **Accepted risk, recorded honestly:** cold-launch premium mobile discovery is a known graveyard; Balatro's mobile success rode seven months of desktop fame. Mitigations live in the roadmap (App Store featuring bet — accessibility + haptics quality are featuring criteria; TestFlight cohort as community seed; revisit at beta if discovery looks dead). Defold keeps a desktop export one click away if this is ever reversed.

## 2026-06-05 — Business model: premium, no real-money randomness

$7.99–9.99 one-time. All packs/shops run on earned currency only; pack odds printed in-game as an EV-literacy device. Rationale: Apple 3.1.1 odds-disclosure rules, Brazil 2026 minor loot-box ban, Australia 15+ chance ratings, and the Balatro/LBaL PEGI-18-for-imagery saga make real-money gacha radioactive for a casino-energy educational game. (docs/research/cards.md §2)

## 2026-06-05 — Sim invariants: determinism + no offline progress

Seeded, deterministic, fixed-timestep (~10 Hz) sim with per-system PRNG substreams, integer-valued state, no libm transcendentals, no `pairs()` in sim code — from day one (unretrofittable). Time freezes when the app closes; no appointment mechanics, ever. Bounded catch-up stays a one-function policy switch. (docs/research/localfirst.md)

## 2026-06-05 — Phase 0 complete; flight view: dashboard-first, portrait

All three gates cleared. 0a: statistics PASS (spikes/0a-stats/VERDICT.md). 0b: Defold on-device PASS — haptics extension + full CLI deploy pipeline (`spikes/0b-defold/tools/deploy-ios.sh`). 0c: **dashboard-first** — Shane rejected the raw dot stream on glass ("no literal flow, doesn't read as customers"); the primary flight view is a real game-UI dashboard in the Late-Night Cable language, **portrait** (landscape possibly later). A *designed* flow visualization may be revisited after look-and-feel exists, but it must earn its place. Sequencing ruling: **mock the actual look and feel before putting more mechanics on screen** — design epic (ad-mpn) is now the active front.

## 2026-06-05 — Art direction pivot: modern social-platform UI, not retro CRT

Author ruling across design rounds 1–3: **"Late-Night Cable" (pixel/CRT/phosphor, indigo-purple) is dead** — round-1 monitor wall rejected as busy; round-2 purple table rejected on palette and pixel type ("too crypto pixelated"). New direction: **TikTok/Meta-grade product design** — near-black dark UI, clean modern grotesque type, rounded cards, pill buttons, one aqua accent + coral live-accent. What survives from the old direction: **cards are the UI** (locked), the settle pass (sequenced one-at-a-time updates — the ceremony queue made visual), fatigue as a quiet status chip, real metric vocabulary. The game hierarchy is now explicit in the UI: client = account header, lanes = campaign shelves, ads = cards in rows; app constructs as tabs (Account / Build / Team / Codex). docs/03-art-direction.md carries an override banner; asset sourcing implications (fonts, no pixel packs) to be re-run at the design epic.

## 2026-06-05 — Design language v0.1: light retro-Facebook, chunky-cute; design from primitives only

Round-4 dark "Snap stage" superseded on palette/mode (author: "not techie dark mode shit"). Locked: **light mode**, retro-FB blue (#3b5998) as primary, paper-gray room, white surfaces, chunky rounded corners, Baloo 2 + Nunito, **game screens are landscape**. Method ruling: **design only the actual constructs** — the component library (`design/design-language.html`) is the source of truth and every component cites the sim module it renders. What survived all five rounds: cards are the UI; the settle pass; state-as-treatment (wear = desaturation); real metric vocabulary. Screens get assembled FROM the library, not invented per-screen.

## 2026-06-05 — LOOP PIVOT: turn-based days + Action Points (live pacing dead)

Author ruling after playing the prototypes: no live/real-time pacing. The loop is **turn-based days** — Day 1, Day 2… with weekday identity (Mon–Sun; weekends shift traffic volume/CPM — real dayparting flavor). Each day: plan + act under an **AP budget** (the day ends when your actions are spent, regardless of bankroll — attention is the scarce resource; flight op-tokens merge into AP), then **End Day** → the day's market resolves in one go and pays out as a sequenced **resolution ceremony** (the settle pass). Brief = one week. What survives untouched: ALL sim math (significance looks were already at day boundaries — 0a's race/bell/carry-over results apply verbatim), fatigue, shimmer, the wave structure (week close = the brief check), pips, autopsy. What dies: the 3-minute live flight window, mid-flight intervention timing, the market director's real-time decision windows (events become day-scoped). docs/01 §2 FLIGHT carries an override banner pending full revision. Tunables flagged: AP per day (~3 + team capacity), weekday modifier table.

## 2026-06-05 — Design-language rulings (v0.2 pass)

From the assessment workflow (design/design-rules.md + design/specs/ + the v0.2 backlog). **Icon/emoji strategy:** Phosphor Icons (MIT), Fill weight, for ALL UI chrome — rasterized white → Defold atlas, runtime-tinted; emoji permitted only as card-art placeholders, shipping (if ever) as Noto Emoji PNGs (Apache 2.0 — Apple's set is unlicensable on Android and App Review 5.2.5 bans embedding it); one icon set, one weight, icons and emoji never share a surface. **Cross-spec contradictions resolved** (accepted the synthesizer's recommendations; author veto open): synchronized shimmer phase for multiple Learning chips; one small-chip token owned by the chips group; `.pricetag` dissolved (upgrade tile + one blue price atom); resources owns the parameterized spend-token (AP = a parameter set); one shared meter-bar atom (score/gates/track-record). Color law upheld: a color never moonlights — End Day is BLUE (agency), not amber.

## 2026-06-05 — Dynamism rulings: seeds & grammars now; ML rules; diffusion parked

From docs/design/dynamic-content.md (research: docs/research/ondevice-imagegen.md, ondevice-embeddings.md). **Tier 0 ships v1**: seeded brand identities, the naming grammar (`sim/namegen.lua`), the combinatorial logo kit (diffusion's worst case is combinatorics' best case), layered art + curated palette-shift variants — the roguelike fantasy lives in seeds and grammars, as it does in RimWorld and Balatro. **Tier 1 author-time embeddings adopted for tooling only**: style-drift CI gate + baked int8 affinity tables (+≤2.5 MB data, zero runtime ML). **Two standing repo rules:** (1) AMLR-licensed models banned from the product AND from generating shipped data — pipeline models MIT/Apache/CC-BY only; (2) if runtime ML output ever ships, it is presentation-only, forever. **On-device diffusion: parked** — fails size/device-floor/thermal/determinism/style/license audits; three explicit revisit triggers recorded in the proposal (checked yearly, not pre-built). **Image Playground: parked**; the real trigger is iOS 27 third-party model support (zero-bundle path to OUR style), Android asymmetry unsolved.

## 2026-06-05 — Avatars locked; idle anims dropped → player Ad Composer; Brand/Product creators; menu+save

Author rulings after the Artlix toon-render landed:
- **Avatars are the art direction.** Artlix FBX → Blender toon → alpha card art (pipeline: `tools/blender_toon_card.py`). Ortho 4:5 framing, bigger cards. The 6 AI styles stay as fallback/setting layers.
- **Idle-animation library DROPPED.** Instead, posing becomes a *player-facing feature*: the **Ad Composer** gives the rigged skeleton draggable arms/head, lets you place a product in-hand + add text + pick a setting/surface. This kills the retargeting problem entirely — we ship rigged characters, the player poses them. (Supersedes the idle-pose plan from the previous turn.)
- **Brand Creator** (build FIRST): CK3/heraldry-style logo composer — pick an icon (logo mark) + a 2–3 color scheme from a palette + a font for the wordmark (icon + name). This realizes the logo-kit from dynamic-content.md §0.3.
- **Product Creator**: pick a category (beverages → alcoholic/non; makeup → cream/lip-balm…) and a starting product; the brand's logo + label maps onto a 3D product FBX (author sourcing product assets). New products added over time via the creator (the tech tree from brands-and-products.md).
- **Menu + auto-save**: New Game / Load / auto-save, keyed to brand name + logo (the save's identity IS the brand you made).
Planning workflow launched to chart Brand Creator + Product Creator + Ad Composer + menu/save (what exists in sim/, what's missing, build order). Brand Creator is the first build target.

## Open (not yet decided)

## 2026-06-06 — Accessibility v1 scope ruling

**Reduced motion (SHIPPED):** `prefers-reduced-motion: reduce` CSS block disables/flattens all keyframe animations and transitions. In-app Reduce motion toggle (Settings panel) writes `adbuy.reduce-motion` to localStorage; `shared.js` applies `.reduce-motion` body class on every page load so the setting persists across the full app. `ceremony.js` `shake()` is a no-op when the class is present. Both OS and in-app flags feed `isReduceMotionEnabled()` in settings.js — either one is sufficient.

**VoiceOver / TalkBack — v1 explicit ruling:** VoiceOver/TalkBack support is OUT OF SCOPE for Phase 1 and Phase 2. Rationale: the ceremony queue and card-animation surfaces require a semantically rich ARIA layer that doesn't exist yet; adding it now would double the DOM work on screens designed visually-first. Defer to post-Phase-2 when the screen structure is stable. No `aria-*` attributes, no `role` overrides, no focus traps — do not add them ad-hoc either, as partial VoiceOver instrumentation is worse than none. The one exception: interactive buttons already receive focus naturally; do not break that.

**Contrast:** Core text on light backgrounds passes WCAG AA (dark ink on white/paper-gray). Blue-on-white chips (`.chip`, `.cardtag`) are acceptable given their decorative/chip role; not load-bearing text. `var(--dim)` labels are below AA — acceptable at their 9–11px, weight-800, decorative label role. Not revisiting for v1.

**Photosensitivity:** No flashing/strobing effects. `boss-pulse` (0.5s opacity 65%→100% cycle) and `btn-pulse` (1.1s box-shadow only) are below the 3Hz photosensitivity threshold per WCAG 2.3.1. Both are suppressed under reduced-motion anyway.

- **Team cards (the joker row)** — proposed 2026-06-05 (docs/design/team-cards.md): run-scoped hires in desk slots with salaries; effects through real machinery only. Mock added to the sweep (ad-7r3.13). **v1 inclusion is a pivot-review ruling** — it must beat the anti-scope law on the strength of being the missing build-identity driver.
- **Production layer: Ad Builder + Asset Library + composition budget + combination fatigue + strategist hypothesis engine** — proposed 2026-06-05 (docs/design/ad-builder-and-assets.md): team mints assets with provenance; builder composes under a capacity budget (over-stuffing penalized honestly); combination reuse fatigues (the Andromeda echo penalty, mechanical); strategists auto-propose hypotheses — **propose, never decide** (protects the pedagogy). Mocks ad-7r3.14/.15; builder screen ad-mpn.6. **No free-text copywriting in v1** (would need LLM/server — breaks local-first; copy lives in cards). All v1 rulings at pivot review.

- Name: "Addendum" and the in-fiction "ON AIR" are both unsearched (trademark/ASO). Half-day search before any public material.
- Named practitioner reviewer for the Layer-1 truth table and aspect taxonomy (blocking for content authoring at scale, not for Phase 0/1).
- Localization: leaning English-only v1 **with** a locale-ready string layer in the card schema (cheap now, painful later) — confirm before authoring 100+ cards.
- Save portability ("new phone" story): iCloud Documents / Android Auto Backup file copy — in/out decision due by beta (Phase 4) at the latest.
- Dots vs dashboard as primary flight view — answered by the Phase 0 prototype, not by argument.

## 2026-06-05 — ENGINE PIVOT: HTML/JS app via Workbooks/Capacitor; Lua sim via Fengari

Superseding the Defold direction. The game ships as an **HTML/CSS/JS app packaged through Workbooks** (`wb forge mobile` -> Capacitor -> iOS/TestFlight; web + desktop free). Rationale: the mocks *become* the app (zero port), web/desktop/mobile from one codebase, and we dogfood Workbooks. Defold scaffold archived to `spikes/0c-defold-app/` (one screen built, ~nothing lost).
- **The sim core stays canonical Lua** (450 tests, deterministic) and runs in the webview via **Fengari** (Lua VM in JS) — chosen over a TS port to keep ONE tested sim and avoid the JS-mirror drift the mocks started. Turn-based/low-frequency -> perf is a non-issue.
- **Determinism bridge:** all sim `bit` users read a global `bit` first; a 32-bit-masked shim (bxor/lshift/rshift via Lua 5.3 operators) makes Fengari bit-identical to LuaJIT — cross-validated against luajit golden outputs. luajit stays the test/CI runner; Fengari is the runtime.
- **Carried over unchanged:** design language, all mocks, the Blender toon->PNG character pipeline (ships PNGs), the LAN-serve loop. **To add via Capacitor plugins:** @capacitor/haptics, local-first saves (IndexedDB or @capacitor/filesystem). **Gap:** Workbooks packages iOS (+web/desktop) now; Android is a later add.

## 2026-06-06 — Onboarding restructure + Team Designer (build order)

New Game becomes a chained onboarding, each stage fading into the next (no per-stage launch):
**Name (owner) → Brand Creator → Product Creator → Team Designer → one final "Launch your LLC" sign screen** (animated signature inking the business, e.g. "Howl & Pounce LLC") → Dashboard. The owner name is captured up front so NPCs/strategists greet the player by name ("Hey Shane"). The brand step no longer launches — it continues; the single Launch lives at the very end.
- **Team Designer (BUILT this pass — app/team-designer.html):** founding-crew hiring. Left = brand lockup + hiring budget ($1500) + your team (N/4 seats, fire to refund). Right = candidate cards carouseled horizontally; each shows role, trait badges, OUTPUT/CRAFT/STAMINA bars + a hidden INSTINCT ("?") — some stats obfuscated by design. Shuffle re-rolls a candidate (RimWorld-style), Hire within budget. Skill axes mirror sim/team.lua legal-effects (capacity/hook_quality/fatigue) + traits ride along for the strategist. Mock economy in JS for now; wire to a Rust team/wasm bridge next.
- **Still to build:** owner-name step; Product Creator (select-a-product, needs the FBX assets); the final animated-signature Launch screen; greet-by-name in dashboard.
- Brand Creator final button is now "Next" → team-designer (saves brand + resolved display colors); the green "Launch" is reserved for the final sign screen.
