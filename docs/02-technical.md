# Technical plan

Engine decision and rationale: DECISIONS.md. Full comparisons: docs/research/engine.md, docs/research/localfirst.md, docs/research/mobileux.md.

## 1. Stack

- **Engine:** Defold (1.12.x line, monthly releases). Editor-direct signed IPA/AAB from macOS; native extensions compile on Defold's cloud builders (stand up the local extender Docker image during week one so the cloud builder is never a single point of failure).
- **Language:** Lua everywhere. LuaJIT on most platforms, vanilla Lua 5.1 on iOS — see determinism rules below.
- **UI:** Druid (components) + Monarch (screen flow) + built-in `gui.animate` easings. Particle FX via the built-in editor.
- **Shaders:** GLSL materials + Lua render script. Port recipes from licensed sources only: vrld/moonshine (MIT — CRT, scanlines, chromasep, glow), Dragosha/cards-fx-kit (MIT, Defold-native — fake-3D card tilt, dissolve), Ritzy's CC0 foil. Shadertoy (CC BY-NC-SA) and libretro (GPL) are study-only.
- **Fallback:** LÖVE, documented terms in DECISIONS.md. Kept cheap by the architecture rule below.

## 2. The architecture rule

**The simulation is pure, framework-free Lua.** `sim/` modules know nothing about Defold: no `go.*`, no `gui.*`, no engine types. Defold collections/game objects are a presentation shell that renders sim snapshots and feeds it commands. This is what preserves the author's composability requirement, makes the sim runnable headless (CI, balance Monte-Carlo, the Phase 0 notebook), and keeps engine fallback a re-skin rather than a rewrite.

```
addendum/
  sim/            -- pure Lua: market sim, resonance, fatigue, economy, RNG
  content/        -- baked card/lane/client data (generated — do not hand-edit)
  game/           -- Defold collections, gui, render script, materials
  juice/          -- feel primitives: tween/easing, juice_up, shake, dynatext, ceremony queue
  ext/haptics/    -- native extension (iOS Core Haptics / Android VibrationEffect)
  tools/          -- content pipeline, balance sim, schema validator
```

## 3. The six juice primitives (build before any sim features)

Per docs/research/balatro.md — these are the product:
1. **T/VT two-transform easing** — every visible thing chases its target transform with smoothed velocity; nothing teleports.
2. **`juice_up`** — 0.4s damped-sine scale/rotation punch.
3. **Decaying shake accumulator** over a permanent idle sway.
4. **Cursor/touch tilt + fake-parallax shadows** on cards (cards-fx-kit).
5. **Per-letter animated text** (DynaText equivalent) + eased odometer counters.
6. **Two queues:** the non-blocking live sim AND a blocking **ceremony queue** for manufactured reveals (significance bell, wave close, autopsy stamps). Never stream the score.

Audio joins them: rising-pitch scoring ticks (`pitch = base + k·progress`), 3–5 state-crossfaded stems, global pitch-drop on failure. Defold's sound component supports runtime gain/pan/speed (0–50) on playing sounds — verified by the adversarial pass (docs/research/engine-verification.md).

## 4. Determinism (day one; unretrofittable)

Per docs/research/localfirst.md:
- Sim owns serializable PRNG objects — **pure-Lua PCG32/xorshift on 32-bit ints via `bit`** (Defold iOS is vanilla Lua 5.1; `math.random` there is platform C `rand()` — banned in sim code). Named substreams per system derived from the 64-bit run seed; states persist in saves. UI juice gets its own unseeded RNG.
- **Integer-valued sim state** (cents, basis points, counts — exact in doubles to 2^53); divide only at presentation.
- Banned in `sim/`: global `math.random`, libm transcendentals (`sin/exp/pow` → lookup tables), `pairs()` (unspecified order).
- **Fixed timestep:** ~10 Hz market tick; the integer tick counter is canonical time. UI emits commands consumed at tick boundaries — seed + command journal = the replay/debug system and the opt-in bug report.
- CI golden test: fixed seed + content → N headless ticks → state hash, run on desktop and device.

## 5. Saves & local-first

- Three files: `settings.dat` (on change), `profile.dat` (meta, with `.bak` rotation), `run.dat` (snapshot every 5–10s sim time AND on focus-loss; iOS gives no quit guarantee).
- Defold `sys.save` is atomic (temp + rename) natively; `pcall` around `sys.load` with `.bak` fallback. Every file: `save_version` int + checksum; ordered migrations; fixture saves of every shipped version replayed in CI.
- Content referenced by stable string IDs (never reused) + alias/retired table.
- No offline progress: pause sim on background, save, done. Bounded catch-up stays a one-function policy switch.
- **App size budget:** ≤150 MB download (target ≤100; Balatro mobile is ~70–93). Compositional atlas-packed card art, Basis ETC1S textures, OGG audio.
- Future lever (not v1): Defold Live Update for data-only card packs without store review (Apple 2.5.2 permits data, not code).

## 6. Content pipeline

Cards/lanes/clients/tuning are **data, authored offline** (docs/research/cards.md §4):
`JSON/TOML source of truth → combinatorial expansion from ~60 hand-authored archetypes → human curation → author-time-only AI flavor/art assist → schema validator + luacheck → headless Monte-Carlo balance sim in CI → bake to data-only Lua table modules (no functions) in the bundle`.
Loader runs sandboxed. Include a locale-ready string layer in the schema from the start (cheap now; retrofitting into 160 shipped cards is not). Behavior by named effect reference, never inline code. The CI Monte-Carlo also asserts **Layer-1 sign invariance**: for every truth-table entry, the effect's sign holds across all client seeds and the current balance patch — a flipped sign fails the build (the never-flip law gets a machine check, not just human review).

## 7. Mobile feel spec

Per docs/research/mobileux.md, adopted:
- **Portrait, one-handed.** Bottom 25% card fan / middle ad lanes (2–3 visible live slots max) / top read-only metrics. No time-critical buttons in the top fifth.
- **Tap to inspect, drag to commit.** Tap never spends. Drag lifts the card 60–80pt above the finger, magnetic snap ≤64dp, spring snap-back. Tap-to-slot fallback. Hit targets ≥48dp (fanned cards, overlapping invisible hitboxes), ≥56dp live-play buttons. Defer iOS bottom-edge gestures during flights.
- **Haptics: week-one native extension** (~100–300-line Obj-C UIImpactFeedbackGenerator/CHHapticEngine + Java VibrationEffect, cloud-built; engine.md and mobileux.md size it differently — the 2–4 day budget holds either way). Exposed as `haptic.play("event_name")` over a tunable data table. The 10-event vocabulary (card pickup → ROAS jackpot) with iOS intensity/sharpness + Android primitive values is specced in docs/research/mobileux.md. Android: gate on `areAllPrimitivesSupported`, ship 3 capability tiers (whole compositions fail silently otherwise). Shout-class moments authored as AHAP with embedded audio (same-clock sync; ~12ms asynchrony is detectable). Settings: haptics toggle + intensity.
- **Frame-rate policy:** 120 Hz only while a finger is on a card or during payoffs (`CADisableMinimumFrameDurationOnPhone` + `preferredFrameRateRange`), 60 watching, 30 idle. Sim tick decoupled. Perf gate: no visible thermal throttle in a 30-min session on a 3-year-old mid-range Android.
- **Data viz:** one hero number per slot (40–56pt tabular figures), ≤3 micro-metrics with axis-free sparklines, drill-in on tap. Updates batched to 2–4 odometer ticks/s. Okabe-Ito categorical palette, viridis continuous, redundant encoding everywhere (never red/green alone — reading data IS the game). CRT pass user-toggleable day one (battery + accessibility + reduce-motion).

## 8. Known engine risks (tracked)

- defold#8571: subtle iOS frame stutter during touch drag (open since 2024; Godot has the same bug). The Phase 0 spike's draggable card will surface it — this is partly what the spike is *for*.
- Cloud-builder dependency for the haptics extension → mitigate with local extender Docker during week one.
- SDF/bitmap text only — fine for numbers/labels/stylized card text; avoid designs needing complex shaping.
