# Addendum (working title)

A mobile-first, local-first game that simulates running a creative-strategy ad account — and quietly trains you to be a real creative strategist / paid-media buyer while you play.

**Elevator pitch:** The creative strategist's week as a tower-defense wave. Compose ads from cards in a paused Build phase, throw the ON AIR lever, and watch five compressed days of market traffic crash through your audience lanes — customer dots stopping, clicking, converting — while you spend scarce intervention tokens on Kill / Boost / Swap calls. Between waves: a graded autopsy of the hypotheses you pinned, and a shop that sells creative components out of the same bankroll that funds your media spend. Balatro's juice and escalation, real ad metrics, zero gambling economics.

## Status

**Pre-production.** Foundation research + design pass complete (2026-06-05). No code yet. Three Phase 0 gates (statistics notebook, Defold device spike, dots-vs-dashboard) must pass before any production work — see [docs/04-roadmap.md](docs/04-roadmap.md).

## Locked decisions

See [DECISIONS.md](DECISIONS.md) for the full log with rationale. Headlines:

| Decision | Ruling |
|---|---|
| Engine | **Defold** (Lua-native, mobile-first; survived adversarial verification) |
| Core loop | **Campaign Sprint Waves** (Build → Flight → Autopsy → Shop), tuned game-first |
| Identity tiebreaker | **Game first** — pedagogy is load-bearing but never wins a conflict against the loop |
| Platform | **Mobile-first, mobile-only public surface** (iOS lead, Android close behind) |
| Business model | Premium $7.99–9.99, zero real-money randomness, no ads, no FOMO |
| Architecture | Sim core in pure framework-free Lua; Defold is only the presentation shell |

## Document map

| Doc | What it holds |
|---|---|
| [docs/00-vision.md](docs/00-vision.md) | Fantasy, pillars, audience hypothesis, positioning |
| [docs/01-game-design.md](docs/01-game-design.md) | The synthesized core loop, card system, sim model, economy, progression |
| [docs/02-technical.md](docs/02-technical.md) | Engine, architecture, determinism, saves, content pipeline |
| [docs/03-art-direction.md](docs/03-art-direction.md) | "Late-Night Cable" direction, asset tiers, sourcing with licenses |
| [docs/04-roadmap.md](docs/04-roadmap.md) | Phases, gating prototypes, v1 cut-line, risk register, open questions |
| [DECISIONS.md](DECISIONS.md) | Decision log |
| `docs/design/loop-*.md` | The three competing loop designs (full specs, kept as reference) |
| `docs/research/*.md` | Eight research reports (engine, balatro, domain, loops, cards, assets, mobileux, localfirst) + the engine adversarial-verification record |

## How this plan was made

A 17-agent research/design workflow (2026-06-05): 8 parallel web-grounded research tracks → 3 independent core-loop designs → adversarial verification of the engine recommendation (2 skeptics, both failed to refute) → a 3-judge panel (compulsion / pedagogy / feasibility) → a completeness critic. The author then ruled on loop direction, identity, and platform; this synthesis encodes those rulings.
