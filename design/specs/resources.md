# Resources — component spec (assessment of design-language.html v0.1)

> Group: bankroll + interest · trust pips · day track · settle float · Iteration Points.
> Sim sources: `sim/economy.lua` (bankroll, interest, IP), `sim/wave.lua` (pips, day boundaries),
> `design/flows.md` (the turn-based day, weekday identity). Law: `design/design-rules.md`.
> Criteria scored ✓ pass · ~ partial · ✗ fail against "minimal, effective, cute, beautiful."

**Group verdict: REFINE.** Four of five components are sound and need state/motion completion;
the day track needs a REWORK (dots → labeled week strip) that `design/mockups/skeleton.html`
has already prototyped — promote it into the library.

| Component | Minimal | Effective | Cute | Beautiful | Verdict |
|---|---|---|---|---|---|
| Bankroll plate | ✓ | ~ (interest copy lies + ambiguous) | ~ (emoji chrome) | ✓ | refine |
| Trust pips | ✓ | ✓ | ~ (blank rects) | ✓ | keep + add burn beat |
| Day track | ✓ | ✗ (post-pivot: no weekday identity) | ~ | ✓ | **rework → Week Strip** |
| Settle float | ✓ | ~ (no negative form) | ✓ | ✓ | keep + add −$ form |
| IP pill | ~ (long label) | ✓ | ✓ | ✓ | keep + add states |

---

## 1. Bankroll plate (`.bank`)

Renders `economy.lua` bank: one bankroll funds media AND the shop — the spend-vs-compound
tension. Interest: **$1 per $5 held, cap $100 (reached at $500 banked)**.

### Findings

- **F1 — the interface lies (rule 8½).** The v0.1 example shows `$1,240` with `+$24 interest`.
  Per `economy.lua`, $1,240 banked → interest is the **capped $100** ($24 corresponds to ~$120
  banked). Fix the example AND make the sub-line computed, never authored.
- **F2 — emoji chrome.** `💰` violates the icon ruling. Replace with Phosphor **Fill** icon
  (Coins), white PNG tinted `--green`.
- **F3 — interest timing is ambiguous post-pivot.** "at close" could read day-close.
  `docs/01 §2 NEWSSTAND` says interest is per-wave (= per **week** post-pivot); `flows.md`'s
  nightly ceremony list has no interest beat. **Spec: interest pays as the first beat of the
  WEEK CLOSE ceremony.** Copy: `+$100 interest at week close`. (design-rules §5 lists "interest
  payout" among settle-pass items — needs the same clarification there.)
- **F4 — overlap.** `skeleton.html` already renders bankroll as a `.plate` (label + Baloo num),
  same atom as ROAS/stat blocks. Retire the bespoke horizontal `.bank` layout; bankroll =
  **stat-plate atom + one sub-line slot** (interest) + leading icon. One atom, not two.

### States

| State | Treatment | Notes |
|---|---|---|
| resting | green Baloo `type/big-num` tabular, dim Nunito sub-line | sub-line always shows live `interest_due()` |
| earning | digits roll up (count-up) | ceremony-driven only |
| spending | digits roll down, 300ms | trigger: budget commit, shop buy, salary |
| interest-capped | sub-line reads `+$100 interest — at cap` | Balatro's visible-cap legibility; text change only, stays dim. **Missing in v0.1** |
| denied (insufficient funds) | **bank does nothing** — the purchase control carries the disabled/denied feedback | no shake, no red flash (rule 8: no anxiety motion) |

No negative balance exists (`Economy.spend` refuses). No idle animation, ever.

### Animation

| Trigger | Motion | Duration/easing | Haptic |
|---|---|---|---|
| revenue lands (its ceremony beat, after the ad's float) | count-up, digits roll 2–4 ticks/s | 300–800ms ease-out, longer = bigger | Whisper ticks, ≥80ms apart |
| spend (buy/commit) | count-down roll | 300ms ease-out | none (button press owns it) |
| interest beat (week-close ceremony, beat 1) | sub-line **pop** → bank count-up by interest | pop 180ms, then 400ms ease-out | Voice (single CLICK-class) on the pop |

One-at-a-time: the bank never rolls while a float is rising or another beat is playing.

### Variants

**No.** One plate, reused on the Desk left rail and the Newsstand header (the interest sub-line
matters MOST in the shop — keep it visible there; it is the compound-vs-spend lesson).

---

## 2. Trust pips (`.pips` / `.pip`)

Renders `wave.lua` pips (3 per run). Miss a brief = burn a pip + half fee; boss miss or last
pip = FIRED. Process protection: a protected miss still burns the pip but pays a Field-Note bonus.

### Findings

- Color: green is sanctioned by the token table ("pips") — keep, but the burn beat must carry
  shape/motion meaning too (CVD rule: never color-alone).
- Cute is the weakest axis: blank rounded rects read generic. Acceptable (honest, minimal);
  do **not** add a glyph — pips stay geometric tokens.
- **Missing: the burn event** (v0.1 shows only full/spent). The week-close ceremony needs it.
- **Missing: protected-burn sequencing** — burn beat, *then* a Field Note bonus beat. Never
  simultaneous; the order says "you still lose the pip, but your process paid."

### States

| State | Treatment |
|---|---|
| full | `--green` fill on `0 2px 0 #2e7847` shelf |
| spent | `#d4dae6` on `--line2` shelf (the shared spent-token treatment) |
| burning (transient) | see animation — ends in spent |
| last-pip idle | **no special treatment.** No pulse, no red (rule 8). The week-brief copy carries the stakes |

FIRED is not a pip state — it's the Run End setpiece's job.

### Animation

| Trigger | Motion | Duration/easing | Haptic |
|---|---|---|---|
| pip burn (week-close ceremony beat, after the verdict stamp) | **pop** to 1.15× → desaturate to spent → settle down 2px (shelf sag) | 180ms pop + ~300ms ease-out settle (~500ms total) | Voice, dull: iOS transient i 0.7 s 0.15 / Android THUD @ 0.6 — softer than run-fail, never Shout |
| protected burn | pip burn beat completes, **then** Field Note bonus chip lands as its own beat | burn as above; bonus = snap ≤120ms | bonus beat: Voice (card-acquired pair, soft) |

### Overlap — the spend-token atom

Pips, AP dots (`.apdot` in skeleton), and op tokens (`.optoken`) are three renderings of one
grammar: *full color on shelf → gray on gray shelf*. **Ship one parameterized token atom**
(shape × fill × shelf): diamond/blue = AP, rect/green = trust pip. Identical spent treatment,
identical sizes per context. (Post-pivot, op tokens ARE AP — rename `.optoken`; that component
is specced in the verbs group. Note: `.optoken.spent` line 163 of the library contains a stray
Cyrillic `е` in a dead duplicate declaration — delete when touching.)

### Variants

**One justified:** ceremony scale. Topbar pips are ~18×24px — too small for a loss moment.
The week-close ceremony presents the pip row at ~1.5× for the burn beat (same component,
scaled; not a new form). No badge/tile forms otherwise.

---

## 3. Day track → **THE WEEK STRIP** (rework)

v0.1's anonymous 12px dots (`.days`) rendered the dead 5-day live flight. Post-pivot
(DECISIONS LOOP PIVOT, `flows.md`) the day track is **THE turn indicator**: 7 labeled cells,
MON–SUN, weekday identity is mechanical (Mon −10% volume, Fri +10% CPM, Sat/Sun scroll days),
and director events are day-scoped, telegraphed the night before. Dots cannot carry any of
this. `skeleton.html`'s `.weekstrip`/`.wd` is the right shape — promote it.

### Spec

- **7 cells, always** (brief = one week). Labels MON TUE WED THU FRI SAT SUN, `type/label`
  (Nunito 800 caps). Landscape topbar, left position.
- Cell width ≥40px read-only; **if tap-to-inspect ships (free inspect of a day's
  forecast/report), bump to ≥48dp** touch targets — 7×48dp fits the landscape topbar.
- v1: read-only. The dots component is **deleted** from the library — no other system uses
  flight-day dots post-pivot.

### States (per cell)

| State | Treatment | Source |
|---|---|---|
| upcoming | paper/dim — gray text, no fill | rules state model |
| live (today) | `--blue` fill, white label, press-shelf `0 2px 0 #2c4170` | rules say "+ pale ring"; the shelf reads chunkier at cell size — **reconcile in design-rules** (recommend shelf, drop the ring) |
| done | `--blue2` tinted | skeleton uses gray + line-through; rules say `--blue2`. **Follow the rules doc**; strike-through is added chrome (rule 2). Flag for author if the crossed-off-calendar cuteness should win |
| telegraphed | upcoming cell gains `--amberpale` fill + `--amber` label | **NEW STATE, missing everywhere** — "tomorrow's weather" from the director telegraph; amber = telegraph per token table |
| weekend identity | **label only** (SAT/SUN), no color | weekday flavor surfaces in the morning report / stinger copy, not as strip treatment — keeps the strip quiet |

### Animation

| Trigger | Motion | Duration/easing | Haptic |
|---|---|---|---|
| day handoff (last beat of the night ceremony) | today's cell settles to done (**pop**, 180ms) → *then* tomorrow's cell lifts to live (**snap**, ≤120ms slight overshoot) | two sequenced micro-beats, never simultaneous | Voice on the live-cell snap (this IS "day close" from rules law 3) |
| telegraph lands (night ceremony, with the director toast) | tomorrow's cell tints amber (**pop**, 180ms) | shares the toast's beat — one event, two surfaces, same frame | none extra (toast owns it) |

No idle motion. The live cell does not pulse (rule 8: the day waits for the player).

### Overlap

- END DAY button subtext ("MON → market" in skeleton) echoes the live cell. Acceptable echo —
  the strip owns identity; the button may restate the *consequence*. One source of truth: strip.
- Night Resolution's "Monday night" title is typography, not a strip variant.

### Variants

**No.** One strip, one home (desk topbar). Run-end matrix does not reuse it.

---

## 4. Settle float (`.float`)

The ceremony's delta stamp: `+$45` over the ad that just settled. Pairs with the bank
count-up (float = delta, bank = new total — that sequence is what makes the arithmetic legible).

### Findings

- **Missing: negative form.** Night beats include costs (salary −$40, swap penalty). Spec:
  `--red` (red = cost-of-people/danger per token table), **sinks** instead of rises —
  direction is the redundant non-color encoding.
- **Never render zero.** `+$0` never spawns (skeleton.html currently initializes a literal
  `+$0` node — don't ship that).
- Value appears **whole** — floats are stamps, not counters. The bank rolls; the float doesn't.

### States

| State | Treatment |
|---|---|
| positive | `--green`, Baloo 800 19px, rises |
| negative | `--red`, same type, sinks |
| zero | does not exist |

### Animation

| Trigger | Motion | Duration/easing | Haptic |
|---|---|---|---|
| an ad's settle beat in the night ceremony | spawn above the ad tile, rise ~24px + fade (sink for negative) | ~700ms ease-out (the rules' **float** spec) | Whisper on spawn (LOW_TICK @ 0.5); the bank roll that follows carries the tick train |

One float at a time, ever — the float must fully land before the bank rolls (rules §5
ceremony order: per-ad float → bankroll count-up).

### Overlap / Variants

No overlap (the float/bank pair is deliberate). **No variants** — one size; magnitude is
expressed by the *bank count-up duration* (longer = bigger), not by float size. Week-fee
payout ceremony numbers belong to the score plate/verdict, not to floats.

---

## 5. Iteration Points pill (`.ip`)

Renders `economy.lua` collection.ip: duplicates auto-convert (1/2/4/8 by rarity); 5 IP + a
worn winner mints a foil V2.

### Findings

- **F1 — `✦` is emoji/glyph chrome.** Replace with Phosphor Fill (Sparkle), tinted `--amber`.
- **F2 — color semantics wobble.** Amber = "wear + warning + target", but IP is minted-value
  currency (gold's meaning). It's amber because gold has no pale tint token. **Keep amber**
  (rules law; amberpale lists "IP pill"), but record the rationale — IP is value-in-waiting
  attached to *worn* winners, which is honestly amber-adjacent. Revisit only at a token review.
- **F3 — label length.** "✦ 7 Iteration Points" is long but friendlier than "IP" jargon; the
  vocabulary-is-curriculum rule doesn't protect "IP" (not a real ads term). Keep full words.
- **F4 — the dup-conversion beat must be SHOWN.** During the pack-rip ceremony a duplicate
  converts to IP; if that isn't its own beat, the player thinks the pull was dead. This is the
  pill's most important moment.

### States

| State | Treatment |
|---|---|
| resting (≥1) | `--amberpale` pill, `--amber` icon + count |
| zero | spent treatment (`#ececf1` / `#9a9aa8`) — **shown, never hidden** (persistent resources don't vanish). Missing in v0.1 |
| gaining | count rolls up + pop |
| spending | count rolls down (mint costs 5) |

Mint-affordability (IP ≥ 5 AND a worn winner exists) is the **mint button's** disabled-state
job, not a pill state.

### Animation

| Trigger | Motion | Duration/easing | Haptic |
|---|---|---|---|
| duplicate converts (pack ceremony beat) | dup card shrinks/slides toward the pill → pill **pop** 1.1× + count rolls `+N` | pop 180ms, roll ≤300ms | Voice — card-acquired pair, soft (TICK @0.6 + CLICK @0.9) |
| mint spend | count rolls down as the V2 mint setpiece begins | 300ms ease-out | none on the pill (the mint setpiece — owned by the card/foil group — is the Shout) |

### Overlap / Variants

Pill atom shared with prices/conf/tags by design — no merge needed. **No variants.** The pill
lives at the Newsstand and the mint sheet only; the Desk does not show IP at rest (it has no
day-scope decision attached).

---

## Group-level findings (ranked)

1. **Rework the day track into the Week Strip** — 7 labeled MON–SUN cells, 4 states including
   the new **telegraphed** state; delete the dots; update design-rules §6 Resources row
   (still says "gray dot") and resolve done-treatment (blue2 vs strike-through) + live
   (shelf vs ring) divergences between rules and skeleton.
2. **Honesty bug in the bankroll example** — $1,240 banked shows +$24 interest; sim says
   capped $100. Make the sub-line computed; add the at-cap text state; pin interest to the
   week-close ceremony (and clarify design-rules §5's "interest payout" item).
3. **Icon ruling sweep** — 💰 → Phosphor Fill Coins (green), ✦ → Phosphor Fill Sparkle
   (amber). No emoji chrome in this group.
4. **Missing event states**: pip burn (+ protected-burn sequencing), negative settle float,
   IP zero/gain/spend, bank interest-capped.
5. **Atom consolidation**: bankroll folds into the stat-plate atom (+sub-line slot);
   pips/AP share one spend-token atom (shape×color parameterized, one spent treatment).

## Open questions for author ruling

- Done-day treatment: rules-compliant `--blue2` fill vs skeleton's crossed-off-calendar
  strike-through (cuter, but added chrome under rule 2).
- Week strip tap-to-inspect (free day forecast/report) — in v1 or read-only?
- Weekend cells: any rest treatment at all, or label + report copy only (this spec: copy only)?
- Interest cadence: confirmed weekly (week-close beat), not nightly — needs a DECISIONS line
  since design-rules §5 currently lists it among settle-pass items.
