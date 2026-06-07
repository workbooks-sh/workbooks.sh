# Spec — Status Chips (v0.1 → v0.2)

> Group: `.chip` + `.c-learning .c-leader .c-limited .c-fatigue .c-spent .c-boss .c-clean`
> Sources cross-checked: `sim/shimmer.lua` · `sim/fatigue.lua` · `sim/wave.lua` · `sim/significance.lua`,
> `design/design-rules.md` (law), `design-language.html` §Status Chips, `mockups/skeleton.html` (usage in anger).
> **Verdict: REFINE.** The vocabulary, color semantics, and pill anatomy are right. The gaps are lifecycle
> (mount/dismount/recovery/re-learning), a one-slot priority rule, the icon ruling, and an untokenized
> badge size already loose in two mockups.

Chips are the one sanctioned "extra element" in the state model (rules §6): they are sim objects
(Meta's literal words), not decoration. They are **read-only** — never tap targets (diagnose taps
belong to the `dchip` set). They change state **only during the night ceremony**, one at a time,
except the two BUILD-time chips (clean test arms/disarms as instant player feedback).

---

## 1. Anatomy (the chip atom)

| Part | Spec |
|---|---|
| shape | pill, `radius/pill` 99px |
| padding | 5px 12px (default) · 2px 8px (badge) |
| type | Nunito 800, 11.5px (default) · 10px (badge); counts use `tabular-nums` so rolls never jitter |
| icon | **one Phosphor Fill icon, 12px, tinted currentColor** — replaces both the anonymous 7px dot `i` and the text glyphs `★ ⚗` (icon ruling, rules §3; also buys CVD shape-redundancy per chip) |
| fill | pale tint field + saturated ink of the state's token color (exceptions: boss = ink/white; spent = inert gray) |
| border | none — **except** `c-clean`: 2px dashed `--blue2` = "provisional / lab" cue; the only bordered chip, sanctioned |

**Finding (beautiful ✗):** the 7px dot carries no meaning and is identical on every chip — it fails
rule 6 (nothing is decoration) and adds zero CVD redundancy. The Phosphor Fill icon slot fixes both.
Icon picks (art-pass may swap within Phosphor Fill): Learning `hourglass-medium` · Leader `crown` ·
Limited `battery-medium` · Fatigue `battery-low` · Spent `moon-stars` · Boss `star` · Clean `flask`.

**Token finding:** spent gray `#ececf1/#9a9aa8` is hardcoded here AND in `cx-unseen`. Name it
(`--inert`/`--inertink`) — it is the shared "out of play" treatment, on purpose.

---

## 2. The seven chips — criteria + states

Scores: ✓ pass · △ passes with the named fix · ✗ fails.

| Chip | Sim source | Min | Eff | Cute | Btfl | Named failures |
|---|---|---|---|---|---|---|
| Learning `n/10` | shimmer.lua | ✓ | △ | ✓ | ✓ | missing **re-learning** (post-SWAP reset); shimmer cap rule unspecified |
| Leader | wave.lua | ✓ | △ | ✓ | ✓ | collides with wear states in the single slot — no priority rule |
| Creative Limited | fatigue.lua | ✓ | ✓ | △ | ✓ | clinical words are curriculum (rule 5) — the icon supplies the cute |
| Creative Fatigue | fatigue.lua | ✓ | ✓ | △ | ✓ | same; recovery direction unspecified |
| Spent | fatigue.lua | ✓ | ✓ | ✓ | △ | unshared gray token (above) |
| ★ Launch Week | wave.lua `is_boss` | ✓ | ✓ | ✓ | △ | `★` text glyph violates icon ruling |
| ⚗ Clean Test | significance.lua + bench | △ | △ | ✓ | △ | `⚗` glyph; armed/broken/minted lifecycle unspecified; only bordered chip (keep, document) |

### Full state sets (cross-checked against the sim)

**Wear chips** — `Fatigue.status()` returns `FRESH | CREATIVE LIMITED | CREATIVE FATIGUE | SPENT`:

| Sim state | Chip rendering |
|---|---|
| FRESH | **no chip** — absence is the state; chip mounts on first LIMITED transition, dismounts on recovery to FRESH |
| CREATIVE LIMITED | amber chip (hook mult ≤ 850) |
| CREATIVE FATIGUE | red chip (hook mult ≤ 500, CPA ≥2×) |
| SPENT | gray chip (3 scars) — terminal; the card's retirement ceremony owns the bigger beat |
| recovery (rest) | FATIGUE → LIMITED → FRESH transitions are **required** — `Fatigue.rest()` regenerates; the chip must walk backward too |
| scars 0–3 | **not on the chip** — scars are card-treatment territory (state-as-treatment, rules §6); chip stays binary words |

**Learning chip** — `shimmer.lua`, conversions 0→10 (`CALIBRATION_CONVERSIONS = 10`):

| Sim state | Chip rendering |
|---|---|
| learning (uncalibrated) | chip present, shimmer loop, count `n/10` rolls at each ceremony |
| calibrated (≥10) | **chip dismounts** — calibrated is chip-absence, the ad's steady numbers are the statement |
| **re-learning** (`on_edit` resets conversions) | chip **re-mounts at `0/10`** the moment SWAP lands — missing from v0.1; this is the felt half of the #1-novice-sin penalty |

**Leader** — wave/ads-in-flight: present/absent, re-evaluated each ceremony. Orthogonal to wear
in the sim (an ad can be Leader AND Limited) — see the priority rule below.

**★ Launch Week** — binary, `brief.is_boss`. Mounts with the brief plate, persists all week on it.
One state; failure consequences (FIRED) belong to the run-end ceremony, not the chip.

**⚗ Clean Test** — three contexts, two of which v0.1 omits:
1. **armed** — bench pair differs by exactly one card (dashed border = provisional);
2. **broken** — bench edited so the pair no longer differs by one → chip dismounts silently;
3. **minted** — at autopsy the verdict banks a Field Note; the chip rides onto the note row as the
   badge-size stamp (already mocked in §Knowledge). Same chip, no new treatment.

### The one-slot priority rule (new, required)

An ad tile has **exactly one chip slot** (Snap-restraint: one power number, one status).
Sim states co-occur; the slot resolves by actionability:

```
Learning  >  Creative Fatigue  >  Creative Limited  >  Leader  >  (no chip)
```

Learning masks everything (you can't trust any read yet — shimmer says so); wear words outrank
Leader because they demand a decision and they're the curriculum; Leader shows only on a calibrated,
healthy winner. Matches `skeleton.html`'s implicit `learning > tired > leader`. Boss and Clean
chips live on other hosts (brief plate, bench pair / note row) — never compete for the ad slot.

---

## 3. Animation — ceremony pace, one at a time

Chip transitions are **items in the settle-pass queue** — each ad's settle beat sequences
internally: float lands → number rolls → *then* the chip change pops. Never simultaneous with
another ad's beat. No chip ever pulses, ticks, or drains in the morning (motion law 5).

| Event | Trigger | Motion (rules §5 vocabulary) | Haptic |
|---|---|---|---|
| chip mounts (any) | its ceremony queue item | **pop** — 180ms ease-out, scale 1.12× | Voice |
| chip dismounts (recovered / calibrated / broken) | ceremony item (or BUILD edit for clean) | **return** — 250ms spring, fade + scale out | Whisper (none for clean-broken) |
| Learning count roll `6/10 → 8/10` | ad's settle beat | digit roll, **count-up** 300ms ease-out | Whisper tick |
| Learning → calibrated | ceremony, count hits 10/10 | roll to 10/10 → hold ~250ms → shimmer stops → **return** out | Voice |
| SWAP reset → re-learning | morning, instant (player action) | chip re-mounts via **pop** at `0/10` | Voice — pairs with SWAP's own penalty cue |
| wear advance (fresh→limited, limited→fatigue) | ceremony fatigue tick | **pop** + color crossfade 180ms | **Voice double-knock** — 2× transient i 0.5 / s 0.15, 120ms apart (mobileux §2.2) |
| wear recovery (one stage back) | ceremony | reverse crossfade 180ms, no pop | none — recovery is quiet relief |
| → Spent | ceremony, 3rd scar | chip grays via pop; the card's retire-into-Learnings beat carries the weight | Voice (owned by the card's beat) |
| Leader gained / lost | ceremony, after races advance | pop in / return out; the adtile's pale-green outline fades 180ms **in sync** (one event, two pixels) | Voice |
| ★ boss mounts | brief reveal | stamps with the brief plate — **snap**, ≤120ms slight overshoot | Voice |
| ⚗ clean arms | BUILD, instant feedback | **pop** | Voice |
| ⚗ minted onto note | autopsy ceremony | rides the note row's mint beat — no motion of its own | (note's beat) |

**Shimmer** (`shim` 1.6s linear loop) is ambient state, exempt from one-at-a-time — but motion
law 1 caps visible loops at ~2/screen. **Rule: when >2 ads are learning, serialize the sweeps** —
round-robin, one sweep in motion at a time, ~0.8s gap between chips. State stays truthful
(every learning chip still shimmers), the screen never strobes.

**No Shout-class events in this group.** The bell, the pack rip, and FIRED own Shout; a chip is
never the loudest thing on screen.

---

## 4. Overlap

| Pair | Ruling |
|---|---|
| chips vs `.tag` (aspect tags on cards) | **share the pill atom** (radius, weight, padding scale), stay separate components — tags are static metadata, chips are live status. Unify the padding/size tokens; do not merge. |
| `c-spent` vs `cx-unseen` | same inert gray on purpose — extract the shared token (§1), document the rhyme |
| `c-boss` vs `cx-canon` | the only two ink-filled pills — deliberate "serious" rhyme (rules §4); keep boss icon white, canon star gold so they never read identical |
| Leader chip vs adtile pale-green outline | sanctioned double encoding of one state (CVD redundancy, rules §6 ads-in-flight); animate as one event |
| chip shimmer vs metric-number shimmer | **one shared shimmer atom** (one keyframe def) applied to both chips and learning numbers — never two implementations |
| Pin verdict stamps (CONFIRMED / BUSTED / INCONCLUSIVE) | adjacent status vocabulary owned by the Pin/autopsy group — recommend they reuse this chip atom (badge size) rather than minting a new stamp component; flagged for that spec |

---

## 5. Variants

| Variant | Verdict | Justification |
|---|---|---|
| **default** (11.5px / 5px 12px) | ship | desk, bench, brief plate |
| **badge** (10px / 2px 8px) | ship — **tokenize now** | already in the wild twice as inline overrides: Leader inside `.adtile` (design-language §Composed Ad) and ⚗ on the Field Note row (§Knowledge). Two real usages = a real variant; un-inline them. |
| tile / full-card forms | **rejected** | chips never grow — the card itself is the state canvas (state-as-treatment); a big chip would be chrome |
| interactive / tappable chip | **rejected** | diagnose taps belong to `dchip`; chips stay read-only, so the 48dp floor doesn't apply |

---

## 6. Open questions (sim/author, not blockers)

1. **Ad-level wear binding:** fatigue is per-(card, lane); the adtile chip shows one status. Worst
   component card? Composition-weighted? Sim presentation call — the chip spec works either way.
2. **Re-learning copy:** plain `Learning 0/10` re-mount, or a distinct `Relearning` word? Lean
   plain (rule 5 — Meta says "learning"); the reset itself is the message.
3. Does the boss chip also appear on the week strip (MON–SUN) during a boss week, or only the
   brief plate? Default: brief plate only until a screen proves the need.
