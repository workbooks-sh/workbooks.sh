# SPEC — The Composed Ad

> Assessed 2026-06-05 against `design/design-rules.md` v1.0. Sources cross-checked:
> `sim/composer.lua` (capacity, combo fatigue), `sim/wave.lua` (launch/kill lifecycle),
> `sim/fatigue.lua` (FRESH → LIMITED → FATIGUE → SPENT + scars), `sim/shimmer.lua`
> (uncalibrated → calibrated), `design/flows.md` (the Desk, day ceremony),
> `design/mockups/table-screen.html` (superseded dark mock — structural reference only).
>
> **Verdict: REFINE.** The tile's skeleton (recipe / identity / power number) is right and
> obeys the Snap one-number rule. What's missing: the **board form doesn't exist in v0.1**,
> the state set is ~half-covered, and the Leader variant is an inline-style hack instead of
> a system.

---

## 1. What it is

One composed ad = `[Hook][Visual][Format][Offer]` (+ modifiers, post-v1 ruling) deployed
into a lane. Revenue is its **power number** — the only big number it ever shows
(Snap restraint, rules §2). Two forms, both real:

| Form | Where | Why it's justified |
|---|---|---|
| **Tile** (340px row, exists in v0.1) | autopsy depth list, lane drill-in, bench list | lists need scannable rows |
| **Board card** (~118×158+, MISSING) | the Desk played row — flows.md screen #3, the home screen | "cards are the UI" (rule 1); the Desk centers on played ads; the settle ceremony spotlights them one at a time |

No badge/mini form. No screen needs one — the slot-stack minislot already serves as the
ad's smallest representation inside other components.

**Finding F1 (highest value):** the board form exists only in the dead dark-mode mock
(`table-screen.html`). It must be ported into the v0.1 light language: white card,
2.5px border (rarity never applies — ads aren't rare, cards are), name in Baloo 2,
assembled art well (per ad-builder doc §2: headline strip + visual region + CTA chip,
emoji-placeholder art allowed), revenue power number below in `--green`, one status chip,
the slot recipe as a minislot strip on the card foot. **Do not port the idle wobble**
(`@keyframes idle` rotate loop) — it's live-stream texture; rules §5 law 5 says nothing
pulses at rest in a turn-based day.

## 2. Anatomy (tile form)

| Zone | Content | Tokens | Notes |
|---|---|---|---|
| slot stack | 3–4 minislots, −9px overlap | `radius/inner` 7px, border 2px `--line2` | **F2: tint each minislot by card kind** (hook `#fdebe2`, visual `#e3f1fd`, format `#eee9fb`, offer `#e4f4e9`) — shares the `k-*` atom with the Component Card so the recipe reads by color, not emoji squinting |
| empty slot | dashed border + glyph | `--dim` | **F3:** "+" becomes Phosphor **Bold** (the one sanctioned outline case, rules §3.1) |
| name | "Pain Point × UGC" | `type/card-name` 15px | auto-derived from hook × visual |
| meta line | lane · recency | `type/meta` `--dim` | **F4:** "day 3" predates the loop pivot — use weekday vocabulary: `Cold Intros · live MON` (days have identity now) |
| chip slot | exactly one status chip | hosted chip component | **F5:** the tile *hosts* chips, never restyles them — see §5 |
| power number | revenue | `type/big-num` 21px `--green`, tabular | label `REVENUE` in `type/label` |

Touch: whole tile is tap-to-inspect (≥48dp tall — current ~72px passes). Tap is always
safe; verbs (Kill/Boost/Swap) act on the inspected/board form, not the list row.

## 3. Criteria scorecard

| Axis | Tile | Board form | What fails |
|---|---|---|---|
| Minimal | **4.5/5** | n/a (missing) | one number, three zones — correct. Leader chip crammed inline into the `h4` with style overrides is the only clutter |
| Effective | **3/5** | **0/5** | half the state set unrendered (§4); board form absent so the home screen can't be assembled from the library — rule 6 violation by omission |
| Cute | **3.5/5** | — | the overlapping mini-card stack is the cute move and it works; neutral gray minislots waste it (F2). The middot meta line reads faintly dashboard-y; weekday names fix it for free |
| Beautiful | **4/5** | — | leader treatment via inline `outline:3px` instead of the "border speaks" idiom (border recolor) used everywhere else — inconsistent edge grammar |

## 4. States — the full set (cross-checked against sim)

The law: state = re-treatment of existing pixels + at most one status chip (rules §6).

| State | Sim source | Treatment | In v0.1? |
|---|---|---|---|
| **draft** (builder) | composer slots | dashed empty slots, no power number | partial (empty slot only) |
| **over-capacity** (builder) | `Composer.over_by` / `legibility_x1000` | **MISSING — F6.** The capacity budget is composer.lua's entire job and rule 8½ + game-design §2 demand the penalty be legible *before* launch. Treatment: slot-stack border + weight readout go `--amber` (warning, not danger), projection chain in the Builder shows the floored hook/hold penalty arithmetic. No new chrome on the tile itself |
| **learning** (uncalibrated) | `Shimmer.is_calibrated` < 10 conv | `Learning n/10` chip (exists) + **power number shows dim `$—` until the first night ceremony** — projection lives in the Builder only; the tile never prints a forecast where actuals go (the interface never lies) | chip exists; number treatment unspecified — **F7** |
| **live / calibrated** | shimmer ≥ 10 conv | full color, steady number, no chip | yes (default) |
| **leader** | wave race position | border → `--greenpale`-derived green edge (border recolor, not outline) + `chip--sm Leader` | hacked (inline styles) — **F5** |
| **limited** | `Fatigue.status` = CREATIVE LIMITED | amber chip (exists) + slot stack `saturate(.55)` — the recipe wears like its cards do | chip only — **F8** |
| **fatigued** | CREATIVE FATIGUE | red chip + slot stack `saturate(.55)`, art 65% | chip only — **F8** |
| **spent** | 3 scars | gray chip + whole tile `saturate(.2)` 75% opacity | chip only — **F8** |
| **killed** | `Wave.command kill` → `killed` event | exit via *return* (~250ms collapse) + budget-refund float to bankroll (rules §6 "budget visibly refunds") | **MISSING — F9** |
| **clean test** | `cmd.clean` / bench pair | `c-clean` chip in the chip slot (bench context only) | chip exists, hosting unspecified |
| **settling** (ceremony spotlight) | night resolution queue | board form: lift + scale ~1.07, settle float, count-up, land | only in the dead dark mock — **F1** |

Combination fatigue (`Composer.combo_rate_x1000`) needs **no tile state** — it surfaces
through the fatigue chips arriving sooner. The Builder may warn on a reused combo
(open question for `ad-mpn.6`); the live tile stays quiet.

## 5. Overlap rulings

| Atom | Ruling |
|---|---|
| Status chips | The tile **hosts** the existing chip component in one designated slot. The v0.1 leader example's inline-shrunk chip (`font-size:10px;padding:2px 8px`) must be promoted to a real `chip--sm` size in the **chips group's** spec — one definition, every host reuses it |
| Minislot ↔ Component Card | The minislot is the Component Card's atom-sized form; it must share the `k-*` kind tints (F2) and the worn/spent desaturation filters (F8). One source of truth for kind color |
| Power number + CAPS label | Same atom as `.stat` and `.bank` (big-num over label). Extract as a shared `metric` atom; zero visual change, one definition |
| Lane label | When the Desk groups ads under lane shelves, the tile **drops its lane line** (the shelf header owns it); flat lists keep it. Context prop, not a variant |
| Race/pin participation | Owned by the race + pin components, never echoed on the tile — no pin badge, no race icon. One job per component |

## 6. Animation (trigger · duration · easing · haptic)

The composed ad owns no Shout-class moment — its big beats are ceremony-owned and merely
*render on* it. Everything below obeys one-thing-at-a-time.

| Motion | Trigger | Spec (rules §5 vocabulary) | Haptic |
|---|---|---|---|
| **launch seat** | Builder "Launch" (1 AP, morning) | slots collapse into stack, tile slides onto Desk, *snap* ≤120ms slight overshoot | Voice (slot-snap class: iOS rigid i0.8 / Android CLICK 0.7). NOT the lever moment — END DAY is |
| **settle spotlight** | its turn in the night ceremony queue | *pop*-class lift ~180–250ms ease-out scale ~1.07 → *float* +$X ~700ms rise+fade → *count-up* 300–800ms ease-out (longer = bigger), digits roll 2–4 ticks/s → land. Next ad only after land | Whisper ticks ≥80ms apart; Voice on land. A jackpot-grade payout escalates to the ceremony's *setpiece* — ceremony-owned, rendered on this card |
| **fatigue chip advance** | ceremony only (never mid-day) | chip *pop* ~180ms ease-out; slot-stack desaturation crossfades in the same beat (one event, one element) | Voice — fatigue double-knock (2× dull, 120ms apart) |
| **kill** | KILL verb (free, any morning) | *return* ~250ms spring collapse; refund float travels to bankroll | Voice — celebrated, not mournful; never the fail thud |
| **learning shimmer** | state (ambient), until 10 conversions | 1.6s linear sweep **on the chip only**, never the full tile. **F10 — shimmer-cap collision:** 2–3 fresh launches = 3 looping tiles, breaking the ≤2 ambient-loop law. Ruling: all Learning chips **share one synchronized phase** — in-unison sweeps read as one ambient system, not competing events |
| **rest** | default | **none.** No idle wobble, no pulse, no breathing. The card sits on its shelf (rules §5 law 5) |

## 7. Open questions (for the Desk skeleton / ad-mpn.6)

1. Board-form size at landscape phone density: 3 ads + rail + hand must fit — does 118×158 hold at 4 ads, or does the row scroll?
2. Does the board form show one small diagnostic (HOOK%) under revenue, or revenue only? (Old mock showed both; Snap restraint says lean no until a playtest asks.)
3. Builder combo-reuse warning (combination fatigue pre-read): amber weight glyph or silence until felt?

## 8. Findings index

F1 board form missing (port to light language, no idle wobble) · F2 kind-tint minislots ·
F3 Phosphor Bold "+" · F4 weekday meta line · F5 chip--sm promotion + designated chip slot ·
F6 over-capacity state missing · F7 `$—` until first ceremony · F8 wear desaturation on
slot stack/tile · F9 kill exit + refund float · F10 synchronized shimmer phase.
