# Spec — Events & Shop (v0.1 → v0.2)

> Group: `.toastx` (+ `.close`) · `.pack` · `.pricetag` (single + upgrade)
> Sources cross-checked: `sim/director.lua` · `sim/economy.lua`, `design/design-rules.md` (law),
> `design-language.html` §Events & Shop, `design/flows.md` (post-pivot loop), `DECISIONS.md`
> (LOOP PIVOT + premium/odds ruling), `docs/01-game-design.md` §2 NEWSSTAND, `mockups/skeleton.html`.
> **Verdict: REFINE.** The toast atom, the pack object, and the price language are right.
> Two components need deep refits: the telegraph is still written for the dead live loop
> (a "12s" countdown violates rule 8 and the pivot), and the shop single hides the card it
> sells (fails rule 1). Both fixes *reuse existing atoms* — no new language needed.

This group renders two sim systems: the **market director** (seeded weighted event table,
day-scoped post-pivot — events amplify/mute/hide/tax, never flip a Layer-1 sign) and the
**Newsstand economy** (2 singles + 2 packs + 1 upgrade per restock; one bankroll funds media
AND creative; odds printed by ruling — Apple 3.1.1 + rule 8½).

---

## 1. Atoms this group owns

| Atom | Spec | Used by |
|---|---|---|
| **toast** (`toastx`) | white card, `radius` 12px, `shadow/rest`, 330px, 11px×16px padding; **6px left accent bar** = the state color; copy is `type/body` with a bold colored lead; numbers `tabular-nums` | director telegraph (amber accent), day-close stinger (blue accent) |
| **price** (NEW, unified) | pill `radius/pill`, Baloo 2 700 13px, **white field / `--blue` ink** (buying = agency = blue); unaffordable = disabled gray `#c9cfdd`/`#aeb6c8`; never green (green = money you *have*; the bank owns green) | pack face, shop single (attached to ccard), upgrade tile |
| **upgrade tile** (NEW) | white card, `border/component`, `radius/chunky`; Phosphor Fill icon (tinted `--blue`) + name (`type/card-name`) + one effect line (`type/body`, `--dim`) + price atom; press-shelf (it's tappable) | the Newsstand's 1 upgrade |
| **weather chip** | an instance of the **status-chip atom** (specs/status-chips.md §1) in amber — the active director event on the Desk header | active-day event state |

**Finding (beautiful ✗, fixed by the price atom):** v0.1 ships two price treatments — the
pack's white/blue pill vs the pricetag's green bold. One group, one price. Green moonlit.

**Finding (icon ruling):** `⚡ 📬 🔥 ⬆️` are chrome, not card art → Phosphor Fill, tinted.
The pack's `🎴` is **art-side** (sanctioned placeholder; ships as Noto/commissioned art).

---

## 2. Director telegraph (`toastx`, amber)

`sim/director.lua` — 5 event kinds, telegraph/start/end phases, 1–2 events per week, never day 1.

### Criteria

| Min | Eff | Cute | Btfl | Named failures |
|---|---|---|---|---|
| ✓ | ✗ | △ | ✓ | **"inbound — 12s" is pre-pivot live-loop copy** — a countdown violates rule 8 (no live pressure) and the LOOP PIVOT (events are day-scoped, "telegraphed the night before — no countdowns, just tomorrow's weather"). No active-day state. No per-kind copy/icon. Emoji chrome. The *weather report* framing is the cute opportunity v0.1 misses. |

### States (full set — v0.1 has only one)

| State | When | Rendering |
|---|---|---|
| **forecast** | night ceremony, the eve of the event day | toast as a ceremony queue item: "**Tomorrow:** CPM spike — pricier eyeballs all day" |
| **active** | all of the event day (morning plan included) | toast dismisses with the ceremony; the event persists as a **weather chip** (amber, chip atom) in the Desk's day header + an amber ring on the live weekday dot (coordinate with Resources `days`) |
| **resolved** | that day's close | chip dismounts quietly during the night ceremony; the day-close stinger's numbers already carry the effect — no recap toast |

Amber is the sanctioned telegraph color for **all five kinds** (rules §4 lists telegraphs under
amber = attention-not-danger); valence is carried by icon + copy, never by a second color.

### The 5-kind table (copy is weather-voice; metric names stay real — rule 5)

| Kind | `fx` | Phosphor Fill | Forecast copy |
|---|---|---|---|
| `cpm_spike` | cpm ×1.35 | `trend-up` | Tomorrow: **CPM spike** — pricier eyeballs all day |
| `cpm_dip` | cpm ×0.80 | `trend-down` | Tomorrow: **cheap reach** — CPM dips all day |
| `competitor_entry` | hook ×0.78 | `sword` | Tomorrow: **competitor enters** — hooks land softer |
| `viral_moment` | amplify novelty ×1.5 | `fire` | Tomorrow: **novelty trending** — novelty aspects amplified |
| `metrics_blackout` | hide CVR | `eye-slash` | Tomorrow: **reporting outage** — CVR hidden all day |

(The hidden-metric *treatment* on the CVR stat block belongs to the Score & Metrics group — flagged there.)

### Animation

| Event | Trigger | Motion | Haptic |
|---|---|---|---|
| forecast mounts | its night-ceremony queue slot (plays alone, after stinger per flows.md order) | **pop** 180ms ease-out, slight scale; holds for read; tap-to-advance | Voice |
| weather chip mounts | next morning, with the desk | **snap** ≤120ms, seated with the day strip — not a ceremony beat | none |
| chip dismounts | that night's ceremony start | **return** 250ms | none |

**No loops, no pulsing, no countdowns** — the toast and chip sit still (motion law 5).
No Shout class in this component; an event is weather, not a jackpot.

### Sim note (not a UI blocker)

`director.lua` still places events by tick (`TELEGRAPH_GAP = 72` ticks) with sub-day durations
(270–450 ticks). Post-pivot re-scope: durations quantize to whole days (v1: all events = 1 day),
`telegraph_tick` maps to the prior night's ceremony. The UI states above are written for that.

---

## 3. Day-close stinger (`toastx.close`, blue)

The night ceremony's penultimate beat (flows.md: ads settle → races → fatigue → learning →
**stinger** → director forecast). Blue = the day system's color (day-live/day-done) ✓.

### Criteria

| Min | Eff | Cute | Btfl | Named failures |
|---|---|---|---|---|
| ✓ | △ | △ | ✓ | "**Day 3** close" is pre-pivot — days have weekday identity (MON–SUN). No **net** hero (the day's delta IS the payoff). No loss-day state. `📬` emoji chrome → Phosphor `envelope-simple` (or `moon-stars` — it's the night's receipt). |

### States

| State | Rendering |
|---|---|
| profitable close | "**Wednesday close** — spend $483 · revenue $612 · **+$129**" — net in `--green`, Baloo (float-style) |
| loss close | net in `--red` with the minus sign (rhymes with salary `−$40`; sign = the CVD shape redundancy). No alarm motion — score-loss-not-run-loss; the tone is a quiet ledger, not a siren |
| weekend/weekday flavor | **not this component** — the night overlay's header line owns flavor copy ("weekend scroll — more eyes, cheaper reach"), already mocked in skeleton.html |
| Sunday close | stinger renders normally, then **hands off** to the WEEK CLOSE brief-check ceremony — the stinger never grows into the week verdict |

### Animation — sequenced inside its one queue slot (one thing at a time, even within the beat)

| Step | Motion | Haptic |
|---|---|---|
| toast mounts | **pop** 180ms | Voice |
| spend rolls | **count-up** 300ms ease-out, digits roll | Whisper ticks (≥80ms apart) |
| revenue rolls | **count-up** 400ms, after spend lands | Whisper ticks |
| net stamps | **pop** 180ms — the only emphasized element | Voice |

Interest payout is the **bank's** ceremony beat (Resources group) — the stinger never shows it.

---

## 4. The Pack (`.pack`)

`Economy.open_pack`: $75, 3 seeded pulls at 70/25/5, legendaries never in shop/packs, dups auto-convert to IP.

### Criteria

| Min | Eff | Cute | Btfl | Named failures |
|---|---|---|---|---|
| ✓ | △ | ✓ | ✓ | **The contract isn't printed on it.** DECISIONS (premium ruling): "pack odds printed in-game"; rule 8½: "pack odds are printed"; Apple 3.1.1 requires disclosure pre-purchase. v0.1 shows name + price only — no card count, no odds. The zig perforation and jewel-blue body are exactly right (the only gradient surface in the language — earned, it's the shelf's prize object). |

**Fix:** face carries a `type/label` line under the price — `3 CARDS · 70 / 25 / 5` — and the
**inspect state** (first tap) shows the odds full-size, satisfying disclosure *before* the buy tap.

### States

| State | Treatment |
|---|---|
| shelf (affordable) | as mocked + the contract line; rests on its `0 4px 0` shelf |
| unaffordable | disabled treatment — desaturated body, gray price atom; still visible, still chunky, **no press travel, no haptic** on tap |
| inspect (1st tap) | **pop** lift 1.12×; odds + card count render large; BUY $75 button (btn atom) appears — tap-is-the-safe-verb: money never leaves on the first tap |
| ripping | the setpiece (below) |
| purchased | slot collapses via **return**; the second pack remains; no ghost wrapper |
| desk (diegetic nav) | same component at 0.75× on the Desk edge — tapping it IS the Newsstand door (flows.md nav rule). Shows shelf state only; can't rip from the desk |

### The rip — Shout-class setpiece (700–1100ms), the group's one jackpot

Same pattern as the bell, higher amplitude. Sequence (blocking, tap-to-advance after step 3):

| Step | Motion | Audio/Haptic |
|---|---|---|
| 1. windup | pack shakes ~150ms (anticipation, not anxiety — single wiggle) | riser starts |
| 2. tear | zig strip tears across ~250ms, top peels off | **Shout** — jackpot AHAP (mobileux §2.2: transients i .5/.7/.9 + continuous decay + final thump), same-frame as the tear |
| 3. fan | 3 cards fan out **face-down** | — |
| 4–6. reveals | each card flips **one at a time** (tap or auto ~600ms apart); the flipped card is a real `.ccard` — rarity border speaks immediately | Voice per flip; a **rare** flip adds the gold beat (pause ~250ms + glint) — still Voice (the rip already spent the Shout; ≤1 Shout/10s) |
| dup reveal | card flips, then folds toward the ✦ IP counter with a `+2 ✦` **float** (700ms rise) — conversion is *shown*, never silent | Whisper |
| settle | cards seat into the hand via **return**; bankroll rolls down −$75 (**count-up** 300ms) *after* the last card lands | Whisper ticks |

120Hz during the rip (Shout setpiece exemption); back to 60 at settle.

---

## 5. Shop single (`.pricetag` → DISSOLVED into `ccard` + price atom)

### Criteria

| Min | Eff | Cute | Btfl | Named failures |
|---|---|---|---|---|
| ✗ | ✗ | △ | △ | **It hides the card it sells.** A text pill ("🔥 Pain Point $50") denies the buyer the kind tint, the art, the rarity border, and the **aspect tags — the very information a purchase decision is made on** (the taxonomy is the curriculum). Fails rule 1 (cards are the UI). Also: green price moonlights (§1); no unaffordable state; no dup-preview. |

### The fix — no new component

A shop single renders as **the existing `.ccard` at full size** with the **price atom** pinned
below it (centered, overlapping the bottom edge by ~50%, like the pack's pill). Every ccard
treatment is inherited free: rarity borders (singles roll common/uncommon/rare per
`pick_rarity`), kind tints, aspect tags. Prices match `economy.lua` ✓ ($50/$80/$150).

### States

| State | Treatment |
|---|---|
| affordable | ccard at rest + blue price atom |
| unaffordable | price atom disabled-gray; **card stays full color** (the card isn't disabled, your bankroll is) |
| **owned-duplicate preview** | price atom gains a second line `→ ✦2 IP` — rule 8½: if buying converts to IP instead of a card, the player knows *before* paying. Required state, missing in v0.1 |
| purchased | card flies to hand via **return** 250ms → bankroll rolls down after it lands (sequenced); slot collapses |

### Animation

Buy = tap card (inspect **pop**, optional) → tap price atom (**pressy** 60ms) → purchase
sequence above. Voice haptic on the buy press; Whisper ticks on the bankroll roll. No Shout —
a single is groceries, the pack is the lottery; the contrast is the EV lesson.

---

## 6. Permanent upgrade (`.pricetag` → upgrade tile)

`Economy.UPGRADES`: `extra_op_token` (post-pivot: **+1 AP**) · `third_bench_slot` ·
`faster_unredaction` · `wider_hand`. Run-scoped permanents (breadth-never-power: nothing
crosses runs).

### Criteria

| Min | Eff | Cute | Btfl | Named failures |
|---|---|---|---|---|
| △ | ✗ | △ | △ | A bare name+price pill can't carry 4 upgrade kinds — "Faster Un-redaction" is meaningless without its effect line. Not a card, so the ccard is wrong too; it's a rule change and needs its own (small) shape — that's *good*: shelf shapes differentiate merch (card / pack / tile). |

### The upgrade tile

Icon + name + effect line + price (anatomy in §1). The four:

| Sim id | Name | Effect line | Phosphor Fill |
|---|---|---|---|
| `extra_op_token` | Fourth Cup of Coffee | +1 AP every day | `lightning` |
| `third_bench_slot` | Third Bench Slot | bench fits one more racer | `flask` |
| `faster_unredaction` | Inside Contact | dossiers un-redact faster | `detective` |
| `wider_hand` | Bigger Desk | hold one more card | `hand` |

(Names are placeholder-flavor; effect lines are the load-bearing part. AP copy must say AP, not
"op token" — sim id is stale post-pivot.)

### States

affordable · unaffordable (disabled price atom, tile stays legible) · **purchased — the effect
must visibly land**: the tile flies (**return**) to where its rule lives and the change pops —
e.g., a 4th AP pip **pops** onto the desk strip, the bench's 3rd slot **snaps** in. Settle-pass
principle: show the change land, never just decrement money. Bankroll rolls after.

### Animation

pressy → tile pop → effect-lands beat (pop/snap at destination) → bankroll roll. Voice haptic
on the effect landing. No Shout.

---

## 7. Newsstand shelf notes (screen-level, recorded here so no component is invented later)

- **Skip-shopping** (`Economy.skip_shop` → tempo tag): the existing `btn sec` atom ("Skip — bank
  it") + a `+1 tempo` **float** on press. No new component.
- **Restock** is per-wave/week; the 1-AP weekday "shop visit" (flows.md) shows the *same* stock —
  open sim question, UI unaffected.
- **V2 mint** (`Economy.mint_v2` — IP + worn winner → foil): **not in this group's mock and not
  specced here.** It's a Shout-class gold ceremony and likely lives on the Newsstand screen —
  flagged as a missing component for its own spec (it touches ccard foil treatment + IP counter).

---

## 8. Overlap

| Pair | Ruling |
|---|---|
| telegraph vs day-close stinger | **one toast atom, two accent skins** — keep as one component, two semantics. The toast is scoped to *night-ceremony announcements only*; it is not a general notification system (no other toasts exist — rule 6) |
| stinger vs Morning Report | adjacent, distinct: stinger = the night's receipt (numbers); Report = the morning's 3-line briefing (what changed + Maya). flows.md open-q 3 stays open; **the stinger never absorbs the report** |
| stinger flavor line vs night overlay header | flavor copy (weekend scroll etc.) belongs to the overlay header (already in skeleton.html), not the stinger |
| shop single vs `ccard` | **merge** — single = ccard + price atom (§5); delete the standalone single pricetag |
| pack price pill vs pricetag price | **merge into the price atom** (§1) |
| weather chip vs status-chip atom | shared atom, instance defined here; never competes for the ad tile's one chip slot (it lives in the Desk day header) |
| active event vs Resources `days` strip | the amber ring on the live weekday dot is a second encoding of the same state — coordinate with the Resources spec (one event, two pixels, animate as one) |
| `metrics_blackout` vs stat block | the hidden-CVR treatment is owned by Score & Metrics — flagged for that spec |
| dup conversion vs IP counter (`.ip`) | floats target the Resources group's IP pill; reuse the float atom |

---

## 9. Variants

| Variant | Verdict | Justification |
|---|---|---|
| toast: ceremony default (330px) | ship | the night queue |
| toast: weather chip (active day) | ship — **as a chip-atom instance, not a toast size** | an all-day event needs all-day presence; a transient toast can't carry it (real screen: the Desk) |
| pack: shelf (1×) + desk (0.75×) | ship | flows.md diegetic nav — "tap the pack on the desk → Newsstand" is a locked navigation rule; desk form is non-rippable |
| pack: per-pack-type skins | **rejected** | sim has one pack type; revisit only if `economy.lua` grows types |
| price atom sizes | **rejected** — one size | fits pack face, ccard pin, and tile alike |
| single: badge/row form | **rejected** | the whole finding is that the card must be seen; never shrink it back into a row |
| upgrade tile sizes | **rejected** — one size | one shelf slot, one screen |

---

## 10. Open questions (author/sim, not blockers)

1. **Director re-scope** (sim): quantize event durations to whole days; telegraph = prior night.
   Can two events ever share a day? (Current placement code prevents overlap — keep that law.)
2. Does the weather chip also ride the WEEK BRIEF's Mon–Sun strip when the forecast is known at
   brief time? Default no — events telegraph only the night before (drama beats omniscience).
3. Stinger net vs ROAS: should the stinger also stamp the running week-ROAS vs target? Lean no —
   the score plate owns ROAS; the stinger is the day's ledger line.
4. Pack inspect: does backing out of inspect cost anything? No — inspect is free everywhere
   (flows.md: "inspect anything · FREE").
5. Upgrade flavor names (§6) need the author's pass — effect lines are final, names aren't.
