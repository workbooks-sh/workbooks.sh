# Knowledge group — component spec v1

> Assessed 2026-06-05 against `design/design-rules.md` v1.0. Components: **Field Note** (`.note`),
> **Codex state** (`.codex`), **Diagnosis guess chips** (`.dchip`). Sim sources: `sim/ledger.lua`
> (notes + codex), `sim/diagnosis.lua` (6-case table, guess grading). Surfaces: Autopsy (screen 6),
> Codex drawer (screen 9), Desk DIAGNOSE verb context, Run End matrix reveal (`design/flows.md`).
>
> **Group verdict: REFINE.** Anatomy and palette are right; the group is missing sim states,
> owns zero specified motion despite being a ceremony surface, and is the library's worst
> icon-ruling offender (8 chrome emoji).

---

## 1. Field Note (`.note`)

Renders one run-ledger entry: `{ aspect, stage, metric, direction, n }` (`sim/ledger.lua`).
Minted at Autopsy from clean-test verdicts; nulls auto-bank. The knowledge currency.

### Criteria

| Axis | Score | Notes |
|---|---|---|
| minimal | 4/5 | One row, three slots (direction · claim+evidence · provenance). Inline `style="font-size:10px"` on the flask chip is an override smell — needs a real mini-chip token (§5). |
| effective | 3.5/5 | Claim + bolded metric + stage reads in a second; real vocabulary ✓. But it cannot render a third of the sim's direction space (below) — an interface that can't say "this HURT" lies by omission (rule 8½). |
| cute | 3/5 | The 📈 emoji is doing all the cute work and is banned chrome. Phosphor Fill + token tint must carry it instead. |
| beautiful | 4/5 | Card language consistent (white, 13px radius, rest shadow). |

### States (sim cross-check)

`direction ∈ {-1, 0, +1}` — confirmed in `test/sim/test_ledger.lua` ("direction follows the
WINNER, not the player's call", direction = -1 case exists). **v0.1 renders only +1 and 0. The
−1 state is MISSING.**

| State | Treatment |
|---|---|
| lift (+1) | direction icon: Phosphor Fill `trend-up`, tinted `--blue` (knowledge, not green — green is money only) |
| **hurts (−1)** | **MISSING** — Phosphor Fill `trend-down`, tinted `--blue`. Shape distinguishes, not color (CVD rule) |
| null (0) | Phosphor Fill `circle`/`prohibit`, tinted `--dim`; meta line "null — banked anyway". Same visual weight as ±1 — negative knowledge is celebrated, never dimmed |
| evidence n = 1, 2, 3… | meta line "seen n× this run" (display true n; band math caps at 3 internally — no UI cap needed) |
| provenance: clean-minted | flask mini-chip (shared `c-clean` atom at mini size) — only clean verdicts mint (`record_pin`), so flask appears on every non-null note |
| provenance: null-banked | no chip |

No worn/spent/decay states — notes are permanent within a run. No disabled state — notes are
not interactive in v1 (Autopsy "depth on tap" may later open provenance; defer).

### Animation (owned)

| Event | Trigger | Motion | Haptic |
|---|---|---|---|
| **mint** | Autopsy ceremony queue reaches "notes minted"; one note per queue item, never batched | **snap**: rises 12px + scale .96→1, ≤120ms, slight overshoot; lands, beat, next item | Voice |
| **evidence stack** (existing note gains n) | same queue | **pop**: row scales to 1.08×, 180ms ease-out; evidence digit rolls n→n+1 (~300ms count-up) — digits roll, never teleport | Voice |
| null mint | same queue | identical to mint — same amplitude, same haptic (pedagogy: a null is a payout) | Voice |

At rest: static. No ambient loops (shimmer/foil are reserved elsewhere). Ceremony pace law:
tap-to-advance allowed, simultaneity never.

### Overlap / variants

- Shares its **row skeleton** (icon well · claim sentence with bolded metric · meta line) with the
  Codex row (§2) — extract one `know-row` atom.
- Variants: **NO**. One form serves Autopsy ledger and Codex drawer. No badge/tile form has a
  screen that needs it (forecast-band narrowing in the Builder is the projection chain's job).

---

## 2. Codex state (`.codex`) — pill + the missing row

Renders `Ledger.codex_status` (account-scoped curriculum tracker, "14 of 32 patterns confirmed").

### Criteria

| Axis | Score | Notes |
|---|---|---|
| minimal | 5/5 | Three pills, three treatments — exactly the sim's state set. |
| effective | 3/5 | **The pill alone cannot build screen 9.** `flows.md` lists "codex rows" as a build material; no row exists in the library. Unseen redaction is undefined. |
| cute | 4/5 | Gold star on ink (CANON) is the group's best moment. |
| beautiful | 3.5/5 | `border-radius:12px` breaks the pill law — rules §4: 99px for "anything that names a state". |

### States (sim cross-check)

`codex_status` returns exactly UNSEEN / OBSERVED / CANON — v0.1 has all three. ✓ No missing
states. Notes:

| State | Treatment | Spec additions |
|---|---|---|
| UNSEEN | spent-gray pill (`#ececf1`/`#9a9aa8`), Phosphor Fill `question` (replaces ？) | In the row form, the **claim text is redacted** — gray bar placeholder, not readable text. Precedent: lane dossier redaction (docs/01 §BUILD). Knowledge you haven't earned isn't legible. |
| OBSERVED | `--bluepale`/`--blue`, Phosphor Fill `eye` (replaces 👁) | "Observed — 1 run" is always literally 1 run (≥2 ⇒ CANON), so the count is static copy; keep it — it teaches the replication bar |
| CANON | ink fill, `#ffd76b` star — Phosphor Fill `star` (replaces ★) | The only ink-filled pill besides `c-boss` (rules §6) — protected; no foil loop (foil = legendary/V2 only) |

### Fixes

1. **Radius → 99px.** Codex states name a state; they join the pill family (chips, tags, prices).
   If the author prefers the plate look, record the exception in DECISIONS.md — don't fork silently.
2. **Add the Codex ROW** (the missing component): `know-row` atom + state pill right-aligned.
   Anatomy: state icon well · claim sentence ("Urgency lifts **Hook** on Cold" / redacted bar when
   UNSEEN) · state pill. This is what screen 9 stacks.
3. Progress header ("14 of 32 patterns confirmed") is a **composition of the existing stat block**
   (`type/big-num` + label), not a new component.

### Animation (owned)

| Event | Trigger | Motion | Haptic |
|---|---|---|---|
| UNSEEN → OBSERVED | Run-end Codex reveal queue (or autopsy close), one claim at a time | re-treatment **pop**: bg gray→bluepale, icon crossfades question→eye, scale 1.08×, 180ms ease-out | Voice |
| OBSERVED → CANON | Run-end ceremony queue | ink fill wipes left→right ~250ms, then gold star **stamps** in (scale 1.4→1.0, ~250ms spring). Sequenced one-per-item; multiple canonizations queue | Voice (the run-end wave grade / CASE STUDY stamp owns the Shout — canonization stays under it) |

State changes happen ONLY inside ceremony queues — the Codex drawer browsed mid-day is fully
static (rule 8: no anxiety motion, nothing updates live).

### Variants

**YES — two, both earned:** the bare **pill** (badge form: progress summaries, row trailing
element) and the **row** (screen 9). Nothing else.

---

## 3. Diagnosis guess chips (`.dchip`)

Renders `Diagnosis.CHIPS = { HOOK, HOLD, CTR, CVR, FATIGUE, NO_SINGLE_LEAK }` — the answer
tokens of the 6-case retrieval micro-game. Graded CORRECT/WRONG (`grade_guess`). Appears in the
DIAGNOSE verb context (1st/day free) and the Autopsy guess-first beat.

### Criteria

| Axis | Score | Notes |
|---|---|---|
| minimal | 4/5 | Six chips = six cases, 1:1 with the sim. ✓ |
| effective | 2.5/5 | **The component's whole job is being graded, and it has no selected, correct, wrong, or revealed-answer states.** Also sub-48dp tap targets on a precision-tap micro-game. |
| cute | 3/5 | 😴 🤷 are banned chrome and are carrying the personality. |
| beautiful | 3.5/5 | Chunky plates match the verb language, but radius is 12px vs the verb's 14px — same family, different waistline. |

### States (sim cross-check + interaction spec)

| State | Treatment |
|---|---|
| rest | white plate, 2.5px `--line2` border, `0 3px 0 --line2` shelf (as built) ✓ |
| pressed | translateY(2px), shelf collapses, 60ms (as built) ✓ |
| **selected/committed** | MISSING — chip stays seated in the pressed pose (down, shelf collapsed) while grading resolves |
| **graded CORRECT** | MISSING — chip fills `--amberpale`/`--amber`: the answer IS the leak, same vocabulary as `stat.warn` / `gate.warn`. Never green (green = money only; rules §4 color law) |
| **graded WRONG** | MISSING — wobble then settle to spent treatment (`#ececf1`/`#9a9aa8`); chip is dead for repeat guesses (repeats cost a token — a spent chip can't be re-picked) |
| **revealed answer** (non-selected chip) | MISSING — after a wrong guess, the true chip fills amber |
| row gating | no per-chip disabled state: `Diagnosis.diagnosable()` gates the whole row's existence (below the n floor the chips never appear — guessing before evidence isn't offered) |

### Animation (owned)

Sequence (one thing at a time, never blocking the skim — any tap outside the chips proceeds):

| Step | Motion | Haptic |
|---|---|---|
| 1. commit | pressy 60ms; chip stays seated | Whisper |
| 2. beat | ~200ms hold | — |
| 3a. CORRECT | chip fills amber + **pop** 1.1×, 180ms ease-out | Voice (notification-success class) |
| 3b. WRONG | wobble ±3°, ~250ms, settle to spent; **then** true chip fills amber + pop (sequenced, not simultaneous) | Voice (notification-error, soft) |

Total ≤700ms. No Shout — the bell, pack rip, and wave grade own Shout class (≤1/10s budget).

### Fixes

1. **Touch targets:** current plate is ~37px tall. Minimum 48dp (rules §4 `touch/min`); these are
   in-play answer verbs — pad to ≥48dp height, keep ≥8dp gaps.
2. **Radius 12px → 14px (`--r`)** to match the verb plate it visibly is.
3. **Icons:** 😴 → Phosphor Fill `moon` (or `battery-low`), tinted `--red` (fatigue's token);
   🤷 → Phosphor Fill `arrows-out`/`question`, tinted `--dim`. Gate chips (HOOK/HOLD/CTR/CVR)
   stay text-only — the metric name is the icon (rule 5).

### Overlap

- `.dchip` ≡ `.verb` minus the cost line — **merge into one pressable-plate atom** (border,
  shelf, radius, Baloo name, pressy) with an optional `vcost` slot. Two CSS forks of the same
  physical object will drift.
- The four gate chips intentionally duplicate funnel-gate *vocabulary*, not the component: gates
  are data, chips are answers. Considered making the gates themselves tappable in guess mode —
  rejected: FATIGUE and NO_SINGLE_LEAK aren't gates, so chips must exist anyway; one answer
  surface beats two. Keep chips; optionally echo-highlight the matching gate on reveal (post-v1).

### Variants

**NO.** Same row in flight context and autopsy.

---

## 4. Group-wide findings

| # | Finding | Severity |
|---|---|---|
| 1 | **8 chrome emoji** (📈 ⚪ ⚗ ？ 👁 ★ 😴 🤷) violate the icon ruling (rules §3) — knowledge is the library's worst offender. All → Phosphor Fill, token-tinted. | must-fix |
| 2 | **Field Note direction −1 missing** — sim banks "hurts" notes; UI can't show them (rule 8½). | must-fix |
| 3 | **Codex row component missing** — screen 9 cannot be assembled from the library as shipped; unseen-claim redaction undefined. | must-fix |
| 4 | **Diag chips have no graded states** and sub-48dp targets. | must-fix |
| 5 | Zero motion specced for the group, yet notes-minted and canonization are ceremony-queue items by design — specs above fill this. | must-fix |
| 6 | Consistency: codex radius 12→99 (pill law), dchip radius 12→14 (verb atom), mini-chip size token replaces inline font-size overrides (also un-forks the adtile's Leader chip). | should-fix |

### Atoms to extract

| Atom | Used by |
|---|---|
| `know-row` (icon well · claim sentence w/ bold metric · meta) | Field Note, Codex row |
| `pressable-plate` (2.5px border, 3px shelf, `--r`, Baloo label, pressy) | verb, dchip |
| `chip--mini` (10px / 2px 8px padding) | note flask, adtile Leader |

### What already works — do not touch

The three-state codex treatment progression (gray → bluepale → ink+gold) is the cleanest
state-as-treatment story in the library; the null note having equal visual weight to a lift
note is correct pedagogy; the claim sentence with the bolded real metric name is the
curriculum doing its job. Refine around these, not through them.
