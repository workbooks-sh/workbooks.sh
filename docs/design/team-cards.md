# Team cards — the joker row (PROPOSAL, 2026-06-05)

**Status: author proposal, not yet ruled into v1.** Raised by Shane mid-mock-sweep. Captured here + bd `ad-7r3` addition; v1 inclusion is a pivot-review ruling.

## The idea

A hiring system: collectible **team cards** — people and orgs with skills/ranks — that sit in persistent **desk slots** for the duration of a run and modify how your whole operation works: output capacity, performance drivers, costs, and the levers of the pattern-matching game. Hire a creative strategist for audience-alignment boosts; hire an offshore agency for raw output at a cost/performance penalty; build a team identity the way Balatro builds a joker board.

## Why this is structurally right

The Balatro research (docs/research/balatro.md) named **the 5-joker row = build identity** as a load-bearing transfer, and the synthesized design never got an equivalent — modifiers are per-ad (≤3, charm-style), nothing persistent defines *this run's strategy*. Team cards fill the slot row with the most natural fiction available: **your agency desk is your build.** It also mirrors the real domain — what separates ad operations is genuinely the team (strategist quality, production capacity, analyst rigor).

## Constraints (from locked decisions)

1. **Run-scoped, always** (vision pillar 3: no meta-progression power). Hires last the engagement and leave at run end. What persists is the *hireable pool* (broadens via unlocks, like card pools) — never the hires. "Long-run boosters" = whole-run boosters.
2. **Effects flow through real machinery, never around it.** Allowed levers: build capacity, information speed/quality, costs, aspect alignment, fatigue management, evidence handling. Banned levers: flat revenue/ROAS multipliers (fake lever — team quality flows through creative quality in reality) and anything that fakes statistics (an "analyst" must never lower the significance bar; n is n).
3. **Truthful tradeoffs.** Every team card with an upside should price it the way reality does: salary, quality, speed, or focus.

## Effect vocabulary (every effect maps to an existing mock system)

| Role archetype | Effect through real machinery | The real-world lesson |
|---|---|---|
| **Creative Strategist** (ranks I–III) | +N to chosen-aspect contributions in her specialty (resonance), or reveals 1 dossier line per wave early (information) | strategists find the angle-audience fit |
| **Offshore Agency** | +2 build capacity (more ads per wave), −5% hook on its ads (quality), low salary | volume vs quality vs cost — the classic call |
| **Senior Editor** | iterations (V2 mints) cost −2 IP; SWAP's relearn penalty halved on her ads | good post fixes creative cheaply |
| **Media Analyst** | clean tests auto-pin; null results bank double Field Notes; never touches significance itself | rigor compounds knowledge, not luck |
| **Production Studio** | pack prices −20%, +1 build capacity, high salary | scale has a monthly invoice |
| **Brand Director** | fatigue accrues 15% slower on-brand (chosen client vertical); −1 build capacity (process) | brand discipline preserves creative life |

Rarity = seniority/rank; legendaries are industry-famous figures (out-of-shop, white-whale mechanic, per cards.md).

## Economy: salaries, not price tags

Hires cost a **per-wave salary** drawn at the Close — a recurring bankroll pressure that fights the interest mechanic directly (carry a big team and your compound engine stalls; run lean and you cap your output). This is the Balatro economy lesson with an agency P&L skin, and it makes firing a verb: cut a hire mid-run, eat a severance, free the salary line. Desk slots: start 2, +1 via upgrades (mirrors joker-slot economics) — suggested cap 4–5.

## Pedagogy check

Teaches org design in a real ad operation: what a strategist vs analyst vs editor actually contributes, why agencies sell volume, why headcount is a compounding cost. All transferable. Anti-lesson risk is contained by constraint 2.

## Extensions (2026-06-05, same session — see [ad-builder-and-assets.md](ad-builder-and-assets.md))

- **Strategists are hypothesis engines:** they auto-propose Pins, clean-test setups, and candidate patterns from accumulated Field Notes; headcount/quality scale proposal speed and hit-rate. **Propose, never decide** — the player still launches, tests, and reads. Mock: `ad-7r3.15`.
- **Production staff mint assets:** "output" is concrete — production hires generate asset cards (with provenance: staff MGX / UGC creator / organic UGC) into the library on a cadence. The library grows because you built the team that grows it.
- **Traits: reading your people (Shane, 2026-06-05).** Hires carry personality traits that shape their *recommendation stream* — making hiring an evaluation skill and proposals a calibration puzzle:
  - **Overconfident / Underconfident** — claimed confidence vs actual hit-rate diverge in a consistent direction per hire. The overconfident strategist says "90% sure" and runs at 60%; the underconfident one hedges everything and quietly runs hot. The player learns this because **every graded proposal feeds the hire's visible track record** (the Pin-grading machinery, reused at the social level).
  - **Creative / Analytical** — the variance axis. Creative hires propose novel, exploratory hypotheses (untested aspects, odd combos — high variance, occasional gems); analytical hires propose evidence-adjacent ones (low variance, reliable, rarely surprising). Neither is better; portfolio-of-advisors is the lesson.
  - **The law extends:** traits affect proposal *distribution and framing only* — never the underlying truth, never the significance machinery. Is the recommendation decent, a hunch, or bravado? The data answers, over time — which is exactly the skill being taught (source calibration is what senior marketers actually do with their teams).

## Open questions (pivot review)

1. **v1 or v1.x?** It's a whole system (hire/fire UI, salary line, ~20–30 team cards) on top of the five bespoke systems. The anti-scope law says it must earn its slice slot. Counterpoint: it may be the missing build-identity compulsion driver the compulsion judge would have demanded.
2. Where do hires appear — Newsstand third shelf, or a separate Hiring board between clients?
3. Do team effects apply account-wide or per-lane (a strategist assigned to a lane = more decisions, more UI)?
4. Interaction with onboarding (hard gate says wave 1 = bare desk; first hire as the wave-2 unlock beat?)
5. Name the system: Team? Desk? Roster? Crew?

## Mock plan (bd ad-7r3 addition)

A thin modifier layer is cheap to mock against existing systems: capacity modifies the wave machine's build limit; salary hooks the Close payout; aspect/fatigue/IP effects compose with resonance/fatigue/economy. The mock proves the composition math and the salary-vs-interest tension before any v1 ruling.
