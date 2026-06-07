# People — component spec v0.1 → v0.2

Group: **hire card** (`.hire`) + **proposal bubble** (`.bubble`), per `design/design-language.html`
§People. Renders `sim/team.lua` (hires, salaries, desk, severance) and `sim/strategist.lua`
(proposals, claimed-vs-actual calibration). Law sources: `design/design-rules.md`,
`docs/design/team-cards.md`, `design/flows.md` (screens 3 Desk, 8 Team Board).

**Verdict: REFINE.** Bones are right (one card, six facts; speech bubble with amber claim).
The calibration display — the group's whole job — fails at-a-glance reading and violates the
color law; half the state set is missing.

**Contingency:** team cards are an open v1 ruling (DECISIONS.md). The **proposal bubble ships
in v1 regardless** — the first-90-seconds flow (flows.md step 3) and the Coach beat use it.
The full hire card ships with the team-system ruling.

---

## 1. Hire card

### Criteria

| Axis | Score | What fails |
|---|---|---|
| Minimal | 4/5 | Six facts is right. But the trait tag "overconfident" is printed at hire time — info the player is supposed to EARN (spoiler, see States). |
| Effective | 2/5 | (a) Claimed-confidence tick is `--red` (`.track .tbar em`); rules §6 People says **amber** — red means fatigue/danger/salary, and the bubble's conf pill is already amber. Library disagrees with itself. (b) Claimed % is encoded only as tick position — not readable at a glance; caption has to explain it. (c) Track record shows no n ("61% right" on 3 grades ≠ on 20 — rule 8½, the interface lies by omission). (d) No rarity vocabulary, though hires are pool collectibles with rank/rarity (team-cards.md). |
| Cute | 3.5/5 | Face well + rank stars are cute; the salary-row + bar block reads slightly form-like. Acceptable. |
| Beautiful | 4/5 | On-system. Trait pills borrow aspect-tag classes (`.tag.urgency`, `.tag.trust`) — wrong semantics, see Overlap. |

### The calibration fix (the headline change)

The gap between claimed and actual IS the character. Make it literal:

```
TRACK RECORD        SAYS 84% · RUNS 61% (18)
[██████████░░░░░░|░░░]
        ▲ blue2 fill = 61% actual      | amber tick = 84% claimed
```

- Label line: `type/label` — **SAYS n%** in `--amber`, **RUNS n%** in `--blue`, graded count
  in parens in `--dim`. Two numbers, two colors, one glance. No caption needed.
- Tick: `--amber` (warning-class, matches the bubble's conf pill). Never red.
- Same axis honesty holds: both are P(right) — the comparison is real arithmetic (rule 8½).
- CVD: tick differs from fill by shape + position, not color alone. ✓

### States (currently 1 of ~9 shown)

| State | Trigger (sim) | Treatment |
|---|---|---|
| candidate | in hiring pool (Team Board) | full card; track area = spent-gray empty bar + "NO HISTORY"; HIRE button in context |
| candidate · blocked | `Team.hire` would fail (desk full / can't pay) | HIRE button gets the disabled treatment; card itself stays full color |
| hired | `Team.hire` true | v0.1 rendering, with fixes above |
| uncalibrated | `track.graded < N` (N≈5, tune) | track bar runs the **shimmer** loop (1.6s linear — same atom as learning metrics); label "CALIBRATING n/N". The strategist herself is in learning phase — exact reuse of the shimmer state model |
| calibrated | `graded ≥ N` | shimmer stops; SAYS/RUNS label + amber tick appear |
| trait hidden | calibration gap not yet established | calibration trait pill renders as **？** (cx-unseen treatment). Nobody's resume says "overconfident" — printing it kills the evaluation puzzle the system teaches (strategist.lua law 3: calibration is *discoverable*). Style trait (creative/analytical) IS visible from hire — it's how she pitches herself |
| trait revealed | consistent gap at threshold | ？ stamps to the named pill (ceremony item, see Animation) |
| assigned *(pending team-cards open Q3)* | assign verb, 1 AP | lane-name chip, `--bluepale` |
| fired | `Team.fire` true | card exits via *return*; severance float (red −$); desk slot reverts to empty |
| rarity | pool def (rank/seniority) | **the border speaks** — same atom as component cards: common `--line2` / uncommon `--blue2` / rare `--gold` / legendary rainbow (industry-famous figures) |

### Animation (owns nothing in v0.1 — all new)

| Trigger | Motion | Spec | Haptic |
|---|---|---|---|
| hire commit | card seats into desk slot | **snap** ≤120ms, slight overshoot | Voice — slot snap (iOS i.8 s.7 / `CLICK`@0.7) |
| fire confirm | card exits, then severance float | **return** ~250ms → **float** ~700ms (−$40, red), strictly sequenced | Voice — single dull thud (fail-lite). NOT Shout: Shout-FIRED is the run-end ceremony only |
| track record update | bar width + RUNS % roll | **count-up** 300–800ms ease-out; plays as ONE ceremony-queue item at autopsy, never live | Whisper ticks, ≥80ms apart |
| trait reveal | ？ pill stamps to name | **pop** ~180ms, scale 1.1 — its own ceremony item ("you've figured Maya out") | Voice |
| salary payday | −$ float off salary line at Week Close | **float** ~700ms, ceremony item before interest (team.lua ordering = the lesson; show it in that order) | Whisper |
| uncalibrated (state) | shimmer sweep on track bar | 1.6s linear loop; counts toward the ≤2-loops-per-screen cap | none |

No idle motion. Salary never pulses (rule 8: no anxiety motion).

### Overlap / shared atoms

- **Tracked-bar atom (MERGE):** `.scoreplate .bar` (green fill + amber target tick) and
  `.track .tbar` (blue2 fill + amber claimed tick) are the same atom: *fill + marker tick*.
  Build once, parameterize {fill, tick, meaning}. The race track (needle on gradient) stays
  separate — a needle is not a fill.
- **Trait pills:** share the `.tag` pill atom but get their own classes — stop borrowing
  `.tag.urgency`/`.tag.trust` (those are resonance inputs on component cards). Trait colors:
  style = `--bluepale`/`--blue`; calibration (once revealed) = `--amberpale`/`--amber`.
- **Header atom (face + name + role):** will be shared by the **client card** (flows screen 2,
  not yet in the library) — design it as one atom now.
- **Rank stars:** `--gold` (rarity/seniority — consistent with gold's meaning), Phosphor Fill
  star per the icon ruling. Face emoji = art-well placeholder (legal per icon ruling §2).

### Variants

- **Full card** (230px) — Team Board. Exists.
- **Face chip** — desk presence: 48–56dp rounded-14 `--bluepale` square (the `.face` atom,
  sized to touch). Justified by a real screen: flows.md nav rule "tap Maya → Team Board" needs
  a persistent Desk tap target, and the bubble's tail needs an anchor.
- **Nothing else.** No badge, no mid tile. Candidate vs hired is a state, not a variant.

### Vocabulary

- "salary / wave" → **"salary / week"** (post-pivot: brief = one week; week close = the check).
- Keep real words: TRACK RECORD, SAYS/RUNS, severance.

---

## 2. Proposal bubble

### Criteria

| Axis | Score | What fails |
|---|---|---|
| Minimal | 5/5 | Who + sentence + claim pill. Right. |
| Effective | 3/5 | (a) No accept affordance — "propose, never decide" requires the player to be able to ACT: a proposal is a pre-Pin (`kind = "pin_suggestion"`) and must hand off to the Pin atom. (b) sim's `rationale` field ("hunch: untested territory" vs "pattern-adjacent: builds on the ledger") is unrendered — it's the discoverable style fingerprint, and it's free (it's text). |
| Cute | 4.5/5 | Tail corner (16/16/16/5), friendly voice. Best-in-group. |
| Beautiful | 4/5 | On-system. Conf pill amber ✓ (matches rules §6 — the hire card must match IT, not vice versa). |

### States

| State | Trigger | Treatment |
|---|---|---|
| fresh | morning, after Morning Report dismisses | pops in anchored to the face chip |
| accepted | player taps **Pin it** | claim stamps into a Pin (📌 atom); bubble dismisses |
| expired | END DAY | fades out quietly — no penalty, no guilt, no nag |

**Stack rule:** max ONE bubble visible (one-thing law). With multiple strategists, extra
proposals queue behind the visible one; the Morning Report's "Maya's note" line is plain text
in the report, not a bubble variant.

### Anatomy additions

- **Pin it** affordance: small chunky secondary button inside the bubble (or whole-bubble tap
  with a pin-glyph hint) — accepting creates the Pin (free, per flows). Dismissal = tap-away.
- **Rationale line:** `type/meta`, `--dim`, prefix-style — *"hunch:"* vs *"from the ledger:"* —
  this is HOW the player reads creative-vs-analytical without a label.
- Conf pill keeps the verbal pattern **"says n% sure"** — same words and amber as the card's
  SAYS number (one value, one voice).

### Animation

| Trigger | Motion | Spec | Haptic |
|---|---|---|---|
| arrival | **pop** ~180ms ease-out, transform-origin at the tail (grows out of the face chip) | morning beat only; never during the night ceremony | Whisper (`LOW_TICK`) or none |
| accept | claim line stamps to Pin | **snap** ≤120ms | Voice — pin placement |
| expire | fade + slight sink | **return** ~250ms | none |

No idle bounce, no attention-seeking wiggle. A proposal waits like a sticky note, not a toast.

### Overlap

- **Bubble vs toast (`.toastx`):** keep both, with a hard rule — **people speak in bubbles,
  the market speaks in toasts.** Kills the dead live-mock pattern of "MAYA:" inside the
  flight chyron; post-pivot her voice exists only as bubble + Morning Report line.
- **Bubble → Pin:** explicit handoff; the pin glyph (Phosphor Fill push-pin) appears at accept
  so the player sees the proposal *become* the Pin they already know.
- **Conf pill ↔ hire-card SAYS number:** same sim value family — same amber, same wording.

### Variants

None. One size. (Coach/tutorial use in run-start flow reuses this exact component.)

---

## 3. New atoms this group requires

| Atom | Why | Treatment |
|---|---|---|
| **Empty desk slot** | desk slots are scarce (2 → 4–5 via upgrades); capacity must be visible | hire-card footprint, dashed 2.5px `--line2` border (the `.minislot.empty` language at card scale), dim "＋ HIRE" centered; tap → Team Board |
| **Tracked bar** (merge) | shared by score plate + hire card | fill + marker tick, parameterized |
| **Face chip** | desk presence + bubble anchor | 48–56dp, `--bluepale`, rounded-14 |
