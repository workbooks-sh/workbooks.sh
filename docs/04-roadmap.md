# Roadmap

Solo-dev sequencing. Each phase has an explicit gate; nothing downstream starts until the gate passes. The critic's audit (2026-06-05) drives Phase 0: the plan's two riskiest assumptions are testable for near-zero cost and must be tested **before** production.

## Phase 0 — Kill-fast prototypes (the gates)

**0a. The statistics notebook — THE blocking unknown.**
Real conversions run ~1 per 3,000 impressions; the entire design assumes that compresses 10–50× into a ~3-minute flight while staying fun *and* statistically truthful. Nobody has shown a tuning where both hold.
- Build: headless pure-Lua sim (it becomes `sim/` — not throwaway) + plots. Sweep event-density compression, sim-day length, sequential-test thresholds.
- Pass: a parameter region where (a) a meaningful A/B race resolves within 1–2 flights at honest n, (b) early data visibly wobbles then settles (the peeking lesson reads), (c) Monte-Carlo shows multiple discovery paths clear a 6-wave run — decision quality dominates noise.
- Fail: no such region after honest search → the loop premise is wrong; redesign flight length/structure before any engine work. **This is the kill/pivot criterion.**
- **Status (2026-06-05): PASSED** — all three criteria met; locked parameters and design-shaping findings in `spikes/0a-stats/VERDICT.md`.

**0b. The Defold device spike (5 days).**
One draggable card with squash/stretch + tilt/parallax shadow, foil shader, particle burst, SDF text, **the haptics native extension**, hot-reloaded on a physical iPhone. Stand up the local extender Docker as part of this. Watch for defold#8571 stutter.
- Pass: card feel on glass is credible and iteration loop is fast. Fail: run the documented LÖVE fallback spike (DECISIONS.md) before deciding.

**0c. Dots vs dashboard.**
All three designers and two judges converged: prototype the flight screen's primary view first. Wire the 0a sim to the 0b shell; A/B the dot-funnel against a metrics-first layout on the actual phone. This is the "is watching fun?" kill-fast question.

## Phase 1 — Vertical slice: one wave

One complete Build → Flight → Autopsy → Newsstand wave, placeholder (Tier 0) assets, ~12 cards, 2 lanes, 1 client. Juice primitives 1–6 built here, before sim features beyond the notebook port. Significance engine (one rule), diagnosis table (6 cases), seeded event table, ceremony queue — all at v1-minimum spec (design doc §7). Newsstand scoped to shop UI + pack-rip ceremony only (no economy tuning); a wave-2 brief stub exists so "one more" is testable.
**Gate:** strangers play one wave on a phone, unprompted "one more" rate is observable (the wave-2 stub makes it measurable), and the wave completes in ≤6 min median excluding the Newsstand exit ramp.

## Phase 2 — The run

Trust pips, dollar-curve escalation, fatigue + V2 minting, Codex skeleton, 2 clients, 6-wave Short Engagement, save system + determinism CI in full. Content to ~60–80 cards / 6 lanes via the pipeline (which gets built here, not hand-authoring).
**Gate:** a full run is completable, fatigue forces exploration by wave 4+, and the run-end matrix reveal lands.

## Phase 3 — Feel, pedagogy, breadth

Haptic vocabulary tuned on device; audio (commissioned adaptive theme); autopsy depth layer; Chill mode; daily seeds; onboarding script; content to full v1 budget (~130–160 cards, 10–12 lanes, 6–10 clients); Tier 1→2 art.
**Gate:** practitioner review pass on the Layer-1 truth table + aspect taxonomy (reviewer: open question — must be named by Phase 2's end).

## Phase 4 — Beta

TestFlight cohort (the playtest pipeline given no-telemetry: opt-in seed + input-journal exports + moderated sessions; this is also the audience-validation instrument the critic flagged).

**Learning gate:** guess-first/DIAGNOSE accuracy and Pin calibration must measurably improve across a player's first N runs (derived from journal exports + moderated sessions). Flat diagnostic accuracy means the teaching pillar failed silently — rethink the autopsy/diagnosis layer before ship.

**Discovery checkpoint:** review cohort/press/wishlist signal; if discovery looks dead, this is the decision point for the recorded reversal lever (desktop export — DECISIONS.md, platform entry).

Balance Monte-Carlo in CI. Accessibility pass: text scaling on the data dashboard, reduce-motion variant of the juice stack, photosensitivity review, CVD-simulator gate. Save portability decision lands here at the latest.

## Phase 5 — Ship v1 (iOS, then Android)

Store assets, ratings questionnaires (note Balatro/LBaL PEGI precedent — expect gambling-imagery questions; our printed-odds/earned-currency stance is the answer), pricing $7.99–9.99, App Store featuring pitch (haptics + accessibility quality are featuring criteria — they're also just the product).

## v1 cut-line

**In:** everything in docs/01-game-design.md not marked deferred.
**Out (each must re-justify itself later):** retained-client scaling mode, Playbook/Standing Orders (incl. Playbook-driven instant-resolve grading — the plain Codex-gated instant-resolve unlock stays in per 01 §6), stake-style difficulty ladders, any-lane clean-test detection, effect-size prediction bands, Agency Rush mode, prose diagnosis engine, reactive market director, overnight anything, Live Update content packs, cloud sync, localization beyond the string layer.
**Anti-scope law (the critic's graft-accretion warning):** the judges' combined graft lists approximate building all three designs. Any bespoke-*system depth* beyond 01-game-design.md §7's v1-floor column is out until the slice proves the floor; everything else follows the In/Out lists above.

## Risk register

| Risk | Severity | Mitigation |
|---|---|---|
| Statistics compression has no good tuning | **Existential** | Phase 0a before everything; explicit kill criterion |
| Premium mobile cold-launch discovery (accepted by platform ruling) | High | TestFlight community seed; featuring pitch; Defold keeps desktop one click away if the ruling is ever reversed |
| Five bespoke systems before content | High | v1-floor table; cut-line; slice gate |
| Balatro juice bar vs solo-dev capacity | High | Juice primitives are reusable engine work, built once, first |
| Curriculum sourced from vendor blogs, no named reviewer | Medium | Practitioner review gate by end of Phase 2; truth table is small and auditable |
| Audience unvalidated (who buys this?) | Medium | TestFlight cohorts span the three circles (vision doc); measure which converts |
| Flight interruption fragility (3-min live window vs 3.3-min median session) | Medium | Auto-pause + mid-flight resume is save-system spec, not nice-to-have |
| Name/trademark ("Addendum", "ON AIR") | Low-cost, high-regret | Half-day search before any public material |

## Open questions (owner: author)

1. Practitioner reviewer — who, what cadence, what budget?
2. Time budget — hours/week and target date for the Phase 1 slice?
3. Name search — when?
4. English-only v1 confirmed? (Schema gets the locale layer regardless.)
5. Save portability — iCloud/Auto Backup in v1 or explicitly accepted loss?
