# Pivot-readiness review — mock sweep complete (2026-06-05)

The question the sweep existed to answer: **are the toolchain, structures, setup, and methodology trustworthy enough to pivot from logic mocks to design implementation?**

**Verdict: YES.** 16 sim modules, 392 tests, 4 quantified findings, zero unexplained behavior. Every system in docs/01-game-design.md plus both of Shane's mid-sweep proposals exists as tested, deterministic, framework-free Lua that composes into a full playable (headless) engagement.

## What exists now

`spikes/simcore/sim/` — 16 modules, all <500 lines, zero dependencies, Lua 5.1 + bit (≙ Defold):

| Layer | Modules |
|---|---|
| Foundation (0a-validated) | rng, funnel (now 5-gate w/ optional HOLD), flight, significance |
| World | resonance (Layer-1 truth table + seeded Layer-2), fatigue (staged wear), director (drama-curve events) |
| Play | wave (phase machine + replay guarantee), composer (capacity + echo), economy, team (the joker row), strategist (trait-calibrated hypotheses) |
| Knowledge | shimmer, diagnosis (6-case), ledger (Pins→Field Notes→Codex) |
| Proof | content (schema+validator), golden (hash fixtures + determinism lint), game+bots (the grand mock) |

**The grand mock works:** a full 2-client/6-wave engagement runs headless, deterministic to the cent, through every system at once; three policy bots produce RANDOM 6 / HEURISTIC 11 / ORACLE 11 clears over 20 seeded worlds.

## Methodology verdict

- **Mocks-first is keeping us honest.** Tests written before modules caught: a projection formula that taught false math, two locked parameters fighting each other (FINDINGS #2), a missing funnel gate the diagnosis table required (FINDINGS #3), and a pattern-savvy bot losing to random for lack of wear discipline (FINDINGS #4). None of these would have surfaced from the design docs alone.
- **Determinism held end-to-end:** golden fixture stable, replay guarantee proven, lint enforces the rules mechanically, 0a experiments reproduce bit-identically through three rounds of system additions.
- **The laws are code now:** Layer-1 sign invariance, amplify-never-flip, banned-lever, propose-never-decide, data-only content — each is a test someone has to consciously delete.

## Findings requiring Shane's ruling (spikes/FINDINGS.md)

1. **False bells (~5-8% on null races):** honest statistics. Codex 2-run replication mitigates. *Ruling: add a "the data lied — replicate" ceremony, or let the Codex teach it silently?*
2. **Learning-state carry-over:** ~20% of $400 ads end a flight uncalibrated (penalty excludes CVR now, by necessity). *Ruling: carry learning state across waves (bench-style), and/or raise wave-1 budget floors?*
3. **HOLD gate:** added, threaded; hold-side *wear* still deferred. *Ruling: rubber-stamp at slice time.*
4. **Content scale governs skill ceilings:** perfect play caps ~55% on a 12-card pool; economy tuning must wait for real content scale. *Ruling: accept that v1 brief-line tuning happens in Phase 2-3, not now.*

## v1 inclusion rulings now on the table (each has mock evidence)

| Proposal | Evidence | My read |
|---|---|---|
| Team cards (joker row) | banned-lever law enforced; salary-vs-interest tension is real money | **In** — it's the missing build-identity driver and the mock was cheap |
| Composition budget + echo-fatigue | overload penalty honest; echo made wear discipline half the skill (FINDINGS #4) | **In** — small system, large pedagogical payoff |
| Strategist hypothesis engine + traits | all three laws proven; calibration gap discoverable over ~30 graded proposals | **v1.x candidate** — wonderful, but it sits on top of team cards + ledger UI; the slice doesn't need it |
| Ad Builder + asset provenance/production | design-phase work (ad-mpn.6); no sim risk | Design phase decides the depth |
| Free-text copy | — | **Out** (already recorded) |

## Graduation plan

When Phase 0b (Defold spike) passes: `git mv spikes/simcore/sim sim/` + move tests to `test/sim/` — the modules are framework-free by construction and the runner is path-relative. The golden fixture and lint go into CI as-is. The 0a experiment scripts stay in `spikes/0a-stats/` as historical evidence (they resolve modules via the moved path — one package.path line to update).

## What the sweep deliberately did NOT do

- No engine code, no rendering, no haptics (that's 0b + the design epic ad-mpn)
- No mid-flight time-varying truth (director effects bake as flight averages; shimmer recalibration is per-launch) — both need a wave-machine hook, scheduled for the vertical slice
- No real content (the 12-card demo world is a test fixture, not the game)
- No economy tuning beyond demonstrating the dials exist

## Next human decision points

1. The rulings above (can be one sitting at the start of the design phase).
2. **Phase 0b: the Defold device spike** (ad-mqj.2) — the last Phase 0 gate, and the design epic's prerequisite.
3. The design-implementation epic (ad-mpn): Tier-0 assets, Late-Night Cable component library, Ad Builder prototype, haptics vocabulary, SFX/music direction.
