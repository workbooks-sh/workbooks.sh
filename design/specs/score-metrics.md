# Spec — SCORE & METRICS group (v0.1 review)

> Components: **score plate · stat blocks · funnel gates · A/B race meter + BELL · the Pin**.
> Sim ground truth: `sim/funnel.lua` (gates, metrics computed at presentation), `sim/significance.lua`
> (two-sided pooled z, tabled z-crits, `n_min`), `sim/wave.lua` (looks at `day_end` only, `N_MIN=200`,
> z=2.807 @ family α .05/10 looks; pins → `CONFIRMED/BUSTED/INCONCLUSIVE`), `sim/shimmer.lua`
> (calibration = 10 conversions, SWAP resets). Law: `design/design-rules.md`. Loop: `design/flows.md`
> (the bell rings at NIGHT, in the ceremony queue — never live).
>
> **Group verdict: REFINE.** Geometry and language are right; honesty mappings, state sets, and
> three explicit law violations (Pin naming, red track side, chrome emoji) must be fixed.

## 0. Scorecard

| Component | Minimal | Effective | Cute | Beautiful | Verdict |
|---|---|---|---|---|---|
| Score plate | 5 | 3 — bar scale undefined (mock numbers don't compute); no empty/met states | 4 | 4 | refine |
| Stat blocks | 5 | 3 — leak is color-alone; no shimmer/empty states; pre-guess reveal breaks guess-first | 3 | 4 | refine |
| Funnel gates | 4 | 3 — bar heights map to nothing; no benchmark mark; no pressed state despite being the DIAGNOSE tap surface | 4 | 4 | refine |
| Race meter + bell | 4 | 2 — one bell line on a two-sided test; red B-side; 5 missing states; no n_min state | 3 (emoji) | 3 (muddy gradient) | refine |
| The Pin | 5 | 2 — "Call it:" collides with the CALL IT verb (forbidden); no graded states | 4 | 4 | refine |

## 1. Shared atoms (extract before building any of these)

| Atom | Definition | Users |
|---|---|---|
| `meter` | trough `--paper`, `radius/inner`, fill bar, 0–1 domain **that must be published** (see each component); horizontal or vertical | score-plate bar, gate gbar, race track, hire tbar |
| `marker-tick` | 3px rounded tick standing proud of the trough; amber = target/threshold, red = claimed | score-plate target, race bell lines, hire claimed-confidence |
| `metric-pair` | Baloo 2 800 tabular num over/beside NUNITO 800 CAPS label | score plate, stat block, gate, adtile pow, bank |
| `pin-glyph` | Phosphor `push-pin` Fill + call text — same glyph everywhere a call is shown | Pin pill, race-meter footer |

Rule 8½ applied to every meter: **a bar with an unpublished scale is a lie.** Each meter below
declares its domain; the implementer renders from that formula, never from taste.

## 2. Score plate (`.scoreplate`) — sim/funnel.lua `roas`, target from `Wave.brief`

**Job:** the one number (rule: Snap one-number restraint). ROAS vs the brief line, account-level, on the Desk left rail and the Title screen.

**Bar mapping (new, mandatory):** domain `0 → 1.25 × target`. Tick therefore always sits at **80%**;
fill = `clamp(roas / (1.25 × target), 0, 1)`. Fill crosses the tick exactly at target — stable
geometry across every brief, and the mock's arithmetic finally computes. Fill `--green` (money
progress toward a money line), number `--blue` (sanctioned: "score plate" is listed under blue).

**States**

| State | Treatment |
|---|---|
| empty (no spend yet, Mon morning) | num renders `—` in `--dim`, bar trough only, tick visible |
| live, below target | as mocked |
| **met** (fill ≥ tick) | tick's amber re-renders `--green` the moment fill passes it — same pixels, new ink; nothing added |
| counting (night ceremony) | digits roll + fill animates together as ONE queue item |
| week-stamped | week close re-treats the plate: PASS → green num flash; MISS → num desaturates to spent gray while the pip burn plays (next queue item, never simultaneous) |

**Animation:** owns one motion — **count-up** (300–800ms ease-out, longer = bigger delta; digits
roll, 2–4 ticks/s). Whisper haptic ticks, rate-limited ≥80ms. When fill crosses the tick mid-roll:
single Voice haptic on the crossing frame. No idle motion ever (no-anxiety law).

**Overlap:** bar = `meter` + `marker-tick` atoms. No merge.

**Variants:** **NO.** One size (230px) serves Desk, Title, and week close. The week-close moment is
a *state* (stamped), not a variant.

## 3. Stat blocks (`.stat`) + 4. Funnel gates (`.gates`) — MERGE into one component: **FunnelStat**

Both render HOOK/HOLD/CTR/CVR from `Funnel.metrics`. They are one component with two forms,
sharing `metric-pair`, warn state, shimmer, and empty state:

| Form | Where | Adds |
|---|---|---|
| `block` (the `.stat` row) | at-rest strips: Desk ad context, Builder projection chain | nothing — num + label |
| `gate` (the `.gates` card) | drill-in + autopsy depth | vertical `meter` + benchmark hairline; gate order is the real funnel order (HOOK → HOLD → CTR → CVR) |

**Gate bar mapping (new, mandatory):** domain `0 → 2 × forecast` for that gate in that lane
(forecast center from the projection chain / lane dossier). Benchmark hairline at **50% height**.
Bar below the line = underperforming — the leak becomes *structural* (shortest-vs-line), not
color-alone. Floor height 6% so an empty bar still draws.

**HOLD is optional in the sim** (`hold_given_stop_ppm` nil → `metrics().hold_rate` nil): the HOLD
column is **omitted entirely**, never grayed — 3-gate ads render 3 gates.

**States (both forms)**

| State | Treatment | Source |
|---|---|---|
| empty (imps = 0) | num `—` in `--dim` | funnel returns 0s |
| learning | **one** shimmer sweep masked across the whole row/strip as a single 1.6s loop (four independent shimmers would bust the ≤2-loops-per-screen cap) | shimmer.lua `shimmer_x1000 > 0` |
| calibrated | shimmer stops, numbers sit steady | `is_calibrated` (10 conversions) |
| re-learning (post-SWAP) | shimmer re-enters — same treatment, no extra badge | `on_edit` resets |
| **leak / warn** | amber num **+ Phosphor `drop` Fill 12px before the label** (redundant encoding, and a leak literally reads as a drip — cute earns its keep). **Applies only after the player's diagnosis guess is graded or the engine reveals — never before** (guess-first pedagogy: the UI must not pre-mark the answer) | diagnosis.lua |
| guess mode (gate form only) | gates become tap targets: gain `shadow/press-shelf`, pressy 60ms press-down, ≥48dp targets. A gate that can be tapped must be chunky (rule 4) — the v0.1 gate has no pressed state: fix | DIAGNOSE verb |

**Animation:** gate fills animate on drill-in open: 0 → value, count-up class ~300ms ease-out, a
single left-to-right choreography with ~80ms stagger — one event, one queue item. Guess tap = pop
(180ms, 1.1×) on the chosen gate + Whisper; grade reveal = Voice. Block-form numbers roll only
inside the night ceremony.

**Overlap finding (cross-group):** the Knowledge section's diag chips duplicate Hook/Hold/CTR/CVR
as `.dchip`s. The gates themselves are the diegetic diagnosis surface ("tap where it leaks — a
funnel gate, the FATIGUE chip, or NO SINGLE LEAK"). **Retire the four metric dchips; keep only
`Fatigue` and `No single leak` as chips** beside the gates in guess mode. (Flag to the knowledge
spec.)

**Variants:** the two forms above only — both demanded by real screens (Desk strip / drill-in).
No badge or full-card form.

## 5. A/B race meter + BELL (`.race`) — sim/significance.lua + sim/wave.lua

**Job:** the honest tug-of-war. Post-pivot, the needle moves **only at night** — `wave.lua` looks
at `day_end` ticks only. "Wobbles honestly" now means *discrete, honest day-moves*, never a live
jitter loop (no-anxiety law).

**Geometry fixes (mandatory):**
- **Two bell lines.** `Sig.compare` is two-sided (`z ≥ +z_bell → A`, `z ≤ −z_bell → B`). Amber
  dotted `marker-tick`s at both ends. The single left line in v0.1 is wrong.
- **Kill the red side.** `--redpale` on the B half says "danger" where nothing is being lost
  (color law: red never appears where nothing is lost). Track = plain `--paper` trough; endcaps
  labeled `A` / `B` in `type/meta` ink. The needle's position carries the lead; no tinted halves.
- **Needle mapping (published):** `x = 50% + 42% × clamp(z / z_bell, −1, +1)` toward the leading
  arm (A left, B right; z from `Sig.compare`). Bell lines sit at 8% / 92% — needle touches a line
  exactly at significance. Honest by construction.
- 🔔 in the footer → Phosphor `bell` Fill (icon ruling).

**States** (v0.1 ships only "racing" — five are missing)

| State | Treatment | Source |
|---|---|---|
| too early (`n < 200` either arm) | needle parked center at 40% opacity, track dimmed; n line reads `n=84 — needs 200` | `N_MIN` gate in `Sig.compare` |
| racing | needle at z-position; n in header | day-end looks |
| unpinned | footer: `pin-glyph` ghosted + "no call placed" | `run.pins` empty for this pair |
| pinned | footer: `pin-glyph` + the call (e.g. `A on HOOK`) — same atom as the Pin pill | `pin` command |
| **called early** (CALL IT verb) | needle freezes at current x; stamp `CALLED — A · n=1,400` in ink; **no bell** — grading (right/lucky/wrong) waits for autopsy | CALL IT is the anti-pin; the meter must visibly distinguish player-resolved from evidence-resolved |
| **resolved by bell** | needle rests past the line; verdict text `B beats A +9.2pts (n=2,410)`; loser side label desaturates (state-as-treatment) | `bell` event |
| inconclusive at week close → carry-over | whole meter desaturates toward spent; n line reads `carries over · n=1,847 banked` | bench carry-over |

**Amplitude tiering:** docs/01 §2 — *clean races get the bell ceremony*. Dirty-pair races that
reach significance resolve with a **Voice-class stamp** (needle crosses, verdict text pops 180ms,
double-tick haptic — no freeze, no foil). The full Shout setpiece below is reserved for clean
tests, keeping Shout ≤1/10s and the bell a jackpot.

### THE BELL — full ceremony arc (the flagship setpiece)

Trigger: night ceremony queue reaches this race's item AND this `day_end` look returned a winner
(`bell` event from `Wave.advance`). Plays alone in the queue; tap-to-advance honored after step 6.

| # | Beat | Motion | Duration / easing | Audio + haptic |
|---|---|---|---|---|
| 1 | focus | meter card lifts (pop, 1.1×), rest of ceremony already dim per queue pattern | 180ms ease-out | — |
| 2 | the move | needle travels from yesterday's x to past the bell line; n rolls in the header (one choreography, one item) | 350ms ease-out, digits 2–4 ticks/s | Whisper ticks under the roll |
| 3 | **freeze-frame** | everything halts the frame the needle touches the line — dead silence, no motion | 250ms hold | nothing (the silence IS the beat) |
| 4 | **BELL** | both bell lines flash amber→white once; Phosphor `bell` Fill stamps in at 1.15× pop; one foil sweep crosses the meter card **once** (event, not the 3.2s state loop) | 300ms; sweep 450ms ease-in-out | single bell SFX + **Shout** haptic (mobileux jackpot pattern: rise + 3 ticks + thud), all on the bell frame; haptic never leads visual |
| 5 | verdict | `B beats A +9.2pts (n=2,410)` rolls in (`type/big-num`), loser endcap desaturates | 200ms ease-out | — |
| 6 | pin grade (if pinned) | footer `pin-glyph` re-stamps CONFIRMED / BUSTED (treatments in §6) | 180ms pop | Voice (confirmed: ascending pair; busted: dull double-knock) |
| 7 | release | card returns; queue advances on tap or after ~600ms | 250ms spring | — |

Beats 2–5 total ~1.1s — top of the setpiece band, correct for the flagship (pack-rip class).
A CONFIRMED clean-test pin that mints a Field Note hands off to the *next* queue item — the mint
never plays simultaneously (rule 3).

**Overlap:** track = `meter` atom; bell lines = `marker-tick`; footer call = `pin-glyph` (must
read as the same object as the Pin pill). No merge.

**Variants:** **NO.** One 340px meter serves Desk bench lane and the Night Resolution focus; the
ceremony "focused" presentation is a state, not a size.

## 6. The Pin (`.pin`) — `wave.lua` pins (pre-registration, graded at autopsy)

**Naming violation (fix first):** v0.1 copy is `📌 Call it: A wins on Hook`. docs/01 §2: pins are
pre-data discipline, CALL IT is the in-flight opposite act, "**the names never mix**." Copy becomes
**`PINNED — A wins HOOK`** (Nunito 800 caps for the verb-word, the call in body case). 📌 →
Phosphor `push-pin` Fill.

**States** (`p.verdict` in wave.lua; v0.1 ships only "open")

| State | Treatment |
|---|---|
| open | as mocked: `--bluepale` fill, 2px `--blue2` border, blue text, pin glyph |
| CONFIRMED | `--blue` fill, white text, glyph → Phosphor `check` Fill (knowledge gained — blue is the knowledge color; often chains a Field Note mint) |
| BUSTED | `--redpale` fill, `--red` border + text, glyph → `x` Fill (a wrong call is the one place red on a pin tells the truth) |
| INCONCLUSIVE | spent gray (`#ececf1`/`#9a9aa8`), suffix `n too small`; if the pair is benched: suffix `carries over` |

All four are re-treatments of the same pill — fill, border, glyph swap; nothing added (state law).
The glyph swap replaces the pin icon in its existing slot.

**Animation:** placement = **snap** (≤120ms, slight overshoot) + Voice slot-snap haptic — pinning
is a commit and must feel like seating a card. Grading at autopsy = 180ms stamp pop per pin,
strictly sequenced in the skim queue (pins one at a time, then notes). No idle motion.

**Overlap:** shares the pill atom with chips but stays a distinct component (it's a wager, not a
status); shares `pin-glyph` with the race footer.

**Variants:** **one**, justified — `pin--mini` (glyph + side letter only, e.g. `📌A` rendered in
Phosphor) for the race-meter footer, where the full sentence doesn't fit at 340px. No full-card
form; at autopsy the standard pill is the graded artifact.

## 7. Findings index

1. **Unpublished meter scales** (plate bar, gate heights, needle) violate rule 8½ — mappings now
   defined in §2/§3/§5; mock numbers must be regenerated from the formulas.
2. **Race meter missing 5 states** + single bell line on a two-sided test + red B-side (color law).
3. **Pin "Call it:" naming collision** with the CALL IT verb — explicit docs/01 law; plus all
   graded states absent.
4. **Chrome emoji** (🔔, 📌, and the warn glyphs) → Phosphor Fill per the icon ruling.
5. **Leak = color-alone** on stat blocks (accessibility rule) — add the `drop` glyph + structural
   shortest-vs-benchmark in gate form; and the warn treatment must not appear before the player's
   guess (guess-first pedagogy).
6. **Stat blocks + funnel gates merge** into FunnelStat (block/gate forms) on the shared `meter`
   atom; gates absorb the diagnosis tap job — retire the 4 metric dchips (flag to knowledge spec).
7. **Shimmer loop budget**: a learning ad's 4 metrics shimmer as ONE masked sweep, not four loops
   (≤2 ambient loops per screen).
8. **Bell amplitude tiering**: full Shout setpiece for clean races only; dirty races resolve at
   Voice — keeps the bell a jackpot (≤1 Shout/10s).
