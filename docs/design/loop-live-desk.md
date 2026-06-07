# ADDENDUM — "OPEN HOURS"
## Core-Loop Design: The Persistent Live Desk

**Angle mandate:** A continuously-running ad account you manage like a living thing across sessions. Time flows (pausable, speed controls); multiple campaigns run concurrently; you slot cards into live campaigns, monitor a desk of ticking metrics, and progress through client tiers over days of play. Game Dev Story / Two Point pacing, card-driven.

**Designer:** Live Desk track. Status: complete core-loop spec for judge panel.

---

## 1. The Fantasy in One Sentence

You run a one-person performance agency from a late-night desk of glowing monitors. Your campaigns are always there — paused exactly where you left them — and the desk slowly grows from one struggling cookware client into a wall of ON AIR lamps you can run in your sleep, because by then you've literally taught the game your own playbook.

The unit of play is not a run. It is **the desk**: one persistent, seeded, multi-client account simulation that you tend in 3–10 minute sittings, across weeks of real life. The compulsion loop is the *Two Point / Game Dev Story* loop — "one more day, the review's on Friday" — powered by Balatro's juice vocabulary, not Balatro's round structure.

---

## 2. Headline Decisions (read this if you read nothing else)

| Question | Decision |
|---|---|
| Turn structure | **No rounds.** Continuous sim days with rhythmic ceremonies: Daily Close-Out (soft beat, ~every 60s real time), Weekly Client Review (hard gate, ~every 5–7 min), Contract Autopsy (arc payoff, every few hours of play). |
| Does time advance while the app is closed? | **No. Never wall-clock.** The desk freezes on background/close (auto-save on focus-loss). **But** the player can arm an **Overnight Shift** before leaving: on next launch the sim deterministically fast-forwards a *bounded, player-chosen* 1–3 sim-days under the player's own automation rules, regardless of how long they were actually away. Gift-framed: no decay, no withering, no appointment mechanics. Away 5 minutes or 5 days — identical result. |
| What replaces Balatro's blinds? | **Weekly Client Reviews** (escalating ROAS/CPA-at-spend targets per client) as pass/fail gates; **creative fatigue** as the perpetual pressure that prevents the desk from ever being "solved." |
| What replaces run-reset learning? | **Clients are the run-like unit.** Each client carries a seeded hidden resonance matrix (Layer 2 over fixed-sign Layer 1 truths). Contract end (graduation or firing) triggers the **Autopsy** that reveals the matrix. The desk, card collection, journal, and Playbook persist. |
| Meta-progression power | **Knowledge-speed only.** Persistent unlocks broaden the card pool, add slots/lanes/clients, and accelerate *information* (faster significance, earlier dossier un-redactions). They never add +performance to ads. Protects the educational claim. |
| Intervention scarcity | **Focus meter** (3–6 pips/day): live-hours actions cost Focus; Morning Desk planning while paused is free. Truthy: the real discipline is *don't thrash live campaigns*. Premium game, never monetized — see risks. |
| Engine/UX baseline | Defold, portrait one-handed, three-zone screen, 10 Hz deterministic fixed-tick sim in pure Lua, per the engine/mobileux/localfirst briefs. All adopted as constraints, not re-litigated here. |

---

## 3. Time Model

### 3.1 The sim day
- **Canonical time** = integer tick counter, 10 Hz fixed-timestep (localfirst brief). Wall clock is never consulted by the sim.
- **1 sim day ≈ 60 seconds at 1×**, compressed non-uniformly (Football Manager highlights model):
  - **Overnight (1am–6am): auto-skipped in ~4 seconds** with a whoosh — *unless* an ad is deployed to a night-skewing audience lane (e.g., "Night-Shift Scrollers"), in which case those hours play at normal density. Dayparting becomes diegetic and discoverable.
  - **Peak hours (7–9pm) dilate ~1.5×** with visibly denser dot traffic.
- **1 sim week (7 days) ≈ 5–6 minutes at 1×; ~2.5–3 minutes at routine 2×.** One sim week is the atomic session arc — inside the ≤7-minute loop budget from the loops brief.

### 3.2 Speed controls (core verbs, bottom-corner thumb cluster)
- **⏸ / 1× / 2× / 4×.** Pause is free, instant, unlimited.
- **Implied pause:** opening any drill-in panel, the Light Table (composition), the shop, or the journal pauses the sim. Closing it resumes at prior speed. Reading data never costs sim time — non-negotiable for a data-literacy game.
- **Event auto-slow:** the sim drops to 1× and gently zooms when a flagged moment approaches (significance stamp imminent, fatigue threshold crossing, market event landing), with a generous decision window. Missed moments cost money, never the account.
- **Auto-pause on app background**, always. Save on focus-loss (iOS gives no quit guarantee).
- **Instant-resolve ("Skip to Friday")** is a *late unlock* (Agency Level 3+), gated on demonstrated watching — the watching is the teaching channel.

### 3.3 Offline: the Overnight Shift (the angle's signature feature)
- Unlocked at Agency Level 2, *after* the player has manually run at least two full client weeks. You cannot automate what you haven't demonstrated by hand.
- Before closing the app (or any time from the desk), the player can **arm the shift**: choose 1, 2, or 3 sim-days to advance on next launch. The desk dims; a "NIGHT DESK ARMED" lamp glows on the wall.
- On next launch, the sim **deterministically replays those ticks at maximum speed** (it is literally just running the fixed-tick sim forward — a one-function policy per the localfirst brief), governed by the player's **Standing Orders** (§7.4). The player watches a 20–40 second **Morning Replay** — a chyron-style digest of what happened, skippable, with every Standing Order trigger logged ("2:14am — RULE 'Kill at 2× CPA' fired: killed *Sizzle V2* in Lane 3").
- **Hard fairness guarantees:** advancement is capped (≤3 sim-days) and identical whether you were gone ten minutes or ten days. Nothing ever decays from absence. There are no push notifications nagging you back in v1. The shift is a *gift you set for yourself*, not an appointment.
- This is the mechanic that delivers "returning to check on your account" without FarmVille loss-aversion, clock exploits, or server dependence.

---

## 4. The Desk: Screen Anatomy (portrait, one-handed)

Per the mobileux brief's three-zone law:

```
┌──────────────────────────────┐
│  THE WALL (top ~33%)          │  Read-only. Late-Night Cable monitor
│  ┌────┐ ┌────┐ ┌────┐         │  wall: one mini-monitor per live lane
│  │ROAS│ │HOOK│ │CPM ▲│        │  (hero number 40–56pt tabular figures,
│  └────┘ └────┘ └────┘         │  rolling odometers @2–4 ticks/s, axis-
│  ~~~ chyron ticker ~~~~~~~    │  free sparkline). ON AIR lamps. Chyron
│                               │  scrolls market events. Tap monitor →
│                               │  jump to its lane / drill-in (pauses).
├──────────────────────────────┤
│  THE FLOOR (middle ~40%)      │  2–3 visible CAMPAIGN LANES (vertical
│  ┌─ Lane: New Homeowners ──┐  │  scroll for more; horizontal swipe
│  │ [AD]→ ●●●○──○──○──○     │  │  switches client). Each lane: ad card
│  │ THUMB HOLD CLICK CONVERT│  │  (71×106 class) + the particle funnel
│  │  26%   44%   1.8%  1.2% │  │  of customer dots flowing through 4
│  │ fresh ▓▓▓▓░ freq 1.8    │  │  labeled gates, freshness bar, freq
│  └─────────────────────────┘  │  counter, IN REVIEW / ON AIR / LIMITED
│  ┌─ Lane: Gift Shoppers ───┐  │  / FATIGUED status stamps.
├──────────────────────────────┤
│  THE HAND (bottom ~25%)       │  Card fan (≥48dp effective hitboxes),
│   🂠 🂠 🂠 🂠 🂠   ⏸ 1× 2× 4×    │  tap-to-inspect / drag-to-commit.
│                               │  Speed cluster bottom-corner. Focus
│                               │  pips. No time-critical UI up top.
└──────────────────────────────┘
```

**"Watching the ad perform live" concretely means:** the lane's ad card sits at the left with its ON AIR lamp lit; customer dots stream left→right past it through a horizontal particle funnel with four labeled gates — **THUMBSTOP** (Hook Rate %), **HOLD** (Hold Rate %), **CLICK** (CTR %), **CONVERT** (CVR %). Most dots flow past unmoved. A dot that stops *flashes* at the gate (whisper haptic tick, rate-limited ≥80ms); a conversion rings a register chime with a chip-stack haptic and bumps the lane's ROAS odometer. During learning phase the numbers **shimmer** (visible static on the digits) and carry wide confidence bands that tighten as conversions accumulate. Event density is compressed 10–50× versus reality while displayed percentages stay truthful (domain brief). The Wall's chyron narrates market-director events ("CPM SPIKE: rival cookware brand enters auction +18%"). Threshold ceremonies fire on the **non-blocking celebration layer** (ROAS crosses 1.0 → wall flash + jackpot haptic) — the live sim never blocks; blocking ceremony-queue moments are reserved for envelopes the player opens (Balatro brief's two-queue rule).

---

## 5. The Daily Rhythm (the actual core loop)

The desk has no hard phase gates, but play settles into a strong rhythm. Real-time costs at routine speeds:

### Phase A — MORNING DESK (paused; 30–120s, player-paced)
The sun-up beat. Sim auto-pauses at 6am each sim day with a soft desk-lamp click.
**Verbs (all free — planning costs nothing):**
- **Read** yesterday's Day Report envelope (see Phase C).
- **Compose** ads at the Light Table (§6).
- **Stage** ads into lanes (they enter "IN REVIEW" and go live at the next sim-hour — truthy nod to Meta ad review).
- **Set budgets** per lane (slider, $50 steps); allocate Test Bench vs Scale Engine split.
- **Shop** (if it's restock day), **journal**, **dossiers**, **edit Standing Orders**.
- Tap **OPEN** (the ON AIR master lever, rising 250ms haptic): the day begins.

### Phase B — OPEN HOURS (live; ~45–60s/day at 1×, most days run at 2×)
The watching beat. Dots flow, odometers roll, the desk hums.
**Live intervention verbs (cost Focus, §7.3):**

| Verb | Focus | What it does |
|---|---|---|
| **KILL** | 1 | Drag ad to the shredder. Refunds the rest of today's split budget. Cards return to collection (carrying their per-audience wear). |
| **BOOST** | 1 | +50% budget to one lane for the rest of the day. |
| **DIAGNOSE** | 1 (refunded if correct) | Tap a struggling ad → "Where's the leak?" → tap the funnel gate you believe is failing. Correct → Focus back + Insight +1 + a 25% discount on your next Iterate of that ad. Wrong → the game shows the real leak. This is the diagnostic-localization curriculum as a verb. |
| **ITERATE** | 2 | Clone the ad, **swap exactly one card**; inherits the kept cards' learned stats; partially re-enters learning phase (shimmer returns, smaller). The modular-iteration workflow practitioners actually use. |
| **SCALE** | 2 | Graduate an ad with ≥10 conversions at target CPA from the Test Bench to the Scale Engine (§6.3). |
| **PIN** | free | Tap an insight bubble (Plague-Inc style) that floats off notable events; banks it to the Learnings Journal. |

Caps: max **3 live ads per visible screen**, 5 live per client early game. Missed interventions (a fatigued ad burning budget overnight) cost money — never the client, never the account, in one day.

### Phase C — DAY CLOSE-OUT (soft ceremony; ~8–15s)
At 1am the desk dips to indigo, overnight whooshes by, and a **Day Report envelope** drops onto the desk with a paper-slap haptic. Non-blocking — it sits there until tapped. Opening it (pauses, blocking ceremony queue): a one-card report with eased counters — Spend, Hook Rate, CTR, CVR, CPA, ROAS, each stamped vs. yesterday (▲▼ with redundant glyph+color encoding) — plus at most **one coaching line** generated from the worst funnel discontinuity ("People stop but don't click — your hook writes a check the offer doesn't cash").

### Phase D — WEEKLY CLIENT REVIEW (hard gate; auto-pause; 30–60s)
Every Friday close, per client. The discrete failure gate that replaces blinds.
- The week's tally vs. the contract line: **"ROAS 1.8 at $350/day"** — the client target functions exactly like a Balatro blind, and targets escalate on every pass (more spend, tighter ROAS, eventually CPA caps and diversity requirements).
- **PASS:** retainer paid (agency cash), performance bonus if beaten by ≥20%, reputation +, one dossier line un-redacts, client may offer a tier-up ("we're doubling budget — can you hold ROAS?" — accept/decline is a real tempo bet: declining banks an easier week, Balatro skip-tag style).
- **MISS:** a **STRIKE** (red stamp, pitch-drop). Two consecutive strikes → the client fires you: contract Autopsy runs (§7.5), the lane monitors go to static, Learnings are salvaged. Losing a client hurts income and reputation but never wipes the desk.
- After the review: **shop restock** (Balatro-shaped: 2 cards + 2 packs + 1 permanent upgrade, rarity 70/25/5) and, when reputation allows, **new client offers** (choice of 2, each a sealed brief with vertical, audiences, and target ladder).

**The session exit is built in:** every Day Close-Out is a clean 60-second exit ramp; every Weekly Review is a clean 6-minute one. "The desk is saved. It'll be exactly as you left it."

---

## 6. Cards → Ads → Lanes (composition spec)

### 6.1 Grammar (cards brief, adopted)
**Ad = [Hook] + [Visual] + [Format] + [Offer]** in fixed function slots, plus up to **3 Modifiers** (charm-style). **Audience is not a slot — it is the lane** you deploy into. Onboarding starts with 2 live slots (Hook + Visual); Format unlocks at Agency Level 2, Offer at Level 3, Modifiers at Level 4.

Every card carries 2–4 typed **aspect tags** (e.g., `urgency 3, scarcity 2, trust −1`). The composed ad's aspect vector is the **sum**; resonance scores that vector against the lane's hidden weight profile (Layer 2, seeded per client) sitting on top of never-randomized Layer 1 truths (urgency lifts CTR but fatigues faster; offer dominates CVR; hook dominates THUMBSTOP variance; angle × Schwartz awareness stage determines cold/warm fit).

### 6.2 The Light Table (when and how composition happens)
- Tap an empty lane slot, or drag any card toward the Floor → the **Light Table** slides up over the bottom two zones (implied pause).
- Drag cards from the fan into the glowing function slots; magnetic snap at ~64dp, spring snap-back on miss; the summed aspect block updates live with each snap (whisper haptics per snap, a deeper *thunk* when the ad becomes valid).
- Tap **SLEEVE IT**: the cards fuse into an **Ad Sleeve** with a juice_up punch and a foil shimmer — a single physical object that holds its component cards. Sleeved cards are committed while the ad lives; killing or retiring the ad returns them (with their per-audience wear).
- Drag the sleeve onto a lane slot → **IN REVIEW** stamp (~1 sim-hour) → ON AIR.
- **Iterate** opens the Light Table pre-loaded with the clone and exactly one slot unlocked.

### 6.3 Test Bench vs Scale Engine (per client)
- **TEST BENCH:** 1–3 lanes, fair-split delivery, cheap, deliberately noisy. This is where A/B races run (§7.2). Budget here buys *information*.
- **SCALE ENGINE:** one winner-take-most lane with a **Diversity Meter** (rewards conceptual spread across angle aspects) and an **Echo Penalty** (near-duplicate aspect vectors cannibalize each other) — the Andromeda-era meta encoded. Diminishing returns to spend create the scale difficulty curve. Only ads with **~10–12 conversions at target CPA** may graduate in.
- The constant loop: test → graduate → fatigue drains the engine → feed new diverse concepts. **Fatigue is the desk's perpetual-motion machine** — the account can never be "finished," only kept healthy.

---

## 7. The Pedagogy Spine (where pattern-matching lives)

Every system below maps to a real creative-strategist muscle. Real metric names everywhere, progressive disclosure: meter → meter+% → full Ads-Manager-style table on drill-in.

### 7.1 Hypothesis pre-registration (forming the hypothesis)
When staging ≥2 ads into a Test Bench lane, an optional one-tap prompt: **"Call it: which wins on [Hook Rate]?"** Pick a horse (or "no read"). Correct calls mint **Insight**; wrong calls cost nothing. Over time the prompt deepens ("by how much?" — pick a band). This converts the player's gut into an explicit, scored prediction — the literal scientific loop — and Insight becomes the currency of the knowledge economy.

### 7.2 The A/B race + the peeking problem (testing the hypothesis)
Two odometers climb side by side with a visible **confidence band** bridging them ("TOO CLOSE TO CALL" → narrowing → **SIGNIFICANT** stamp slam, shout-class haptic). Races resolve at a significance threshold, **never a timer**. Early leaders flip mid-race by design — calling a winner early (killing the eventual winner) is a felt, financial mistake. Underfunded or over-fragmented tests crawl toward significance, teaching signal consolidation: too many simultaneous tests starve them all (learning-phase shimmer never sharpens).

### 7.3 Focus and the discipline of not fiddling
Edits to live ads partially reset learning phase (truthy: Meta resets learning on significant edits). The Focus meter (3 pips/day → 6 max) makes live meddling scarce while Morning Desk planning stays free. The game is structurally teaching: *plan in the morning, let it run, intervene rarely and deliberately.*

### 7.4 Standing Orders / the Playbook (externalizing the learning) — signature system
At Agency Level 2 the player gets **Playbook slots** (2 → 8) and a tap-only rule builder:

> **WHEN** [metric: CPA / ROAS / Hook Rate / Frequency / Freshness] [≥ / ≤] [value or "2× historical"] **AFTER** [≥ N conversions / impressions] **THEN** [Kill / Halve budget / Flag for me / Iterate-queue]

These are literally Meta's automated rules, gamified. Standing Orders govern the desk during **Overnight Shifts** and (later) during live hours if armed. The **Morning Replay grades the rules**: every trigger is logged with outcome, and the weekly review includes a Playbook line ("Your rules saved $214 and killed one future winner"). Writing a good rule *is* the proof of learning — the player is forced to compress their pattern knowledge into explicit policy, then watch it perform. This is the long-arc mastery expression of the entire game.

### 7.5 Dossiers, Journal, Autopsy (confirming/denying hypotheses)
- **Audience Dossiers:** each lane has a client-brief sheet — Schwartz awareness stage and aspect-weight lines, **initially redacted**. Statistically significant results un-redact lines automatically ("✓ responds to: curiosity hooks ▲▲"). Insight can buy an un-redaction (anti-frustration). Watching a dossier fill in *is* watching yourself learn.
- **Learnings Journal:** auto-records significant findings and Pinned bubbles, organized by audience archetype and aspect axis. Retired veteran winners (3-cycle fatigue scars) become permanent journal plaques whose buffs only ever **accelerate information** (e.g., "Cookware verticals: significance 15% faster") — never boost ad performance.
- **Contract Autopsy:** when a client contract ends (graduation or firing), the full hidden resonance matrix is revealed against the player's journal — every hypothesis they registered marked CONFIRMED / BUSTED, with the matrix rows they never even tested shown dimmed ("you never tried a founder-story angle on Gift Shoppers"). Lessons land explicitly; per-client seeding means *answers* don't transfer to the next client, but *method* does — which is the whole educational claim.

### 7.6 Fatigue (the load-bearing decay mechanic)
- Per-card-**per-audience** freshness bar on every sleeve, driven by cumulative impressions × frequency. Cold-audience onset around **Frequency 2.5**.
- **Staged decay, truthful order:** THUMBSTOP decays first (visibly fewer dots stopping — the Wuselfaktor itself teaches it), then HOLD, then CTR.
- Status stamps use Meta's literal words: yellow **CREATIVE LIMITED** (CPA above rolling historical), red **CREATIVE FATIGUE** (CPA ≥ 2× historical), with VHS-tracking dissolve creeping over the card art and a double-knock warning haptic.
- **Rest regenerates** freshness partially (bench a winner; rotation is a skill). **~3 full cycles scar permanently** → retirement → journal plaque. Duplicates + Iteration Points can mint a foil **V2** with a *mutated* (not strictly better) aspect vector — different and fresher.
- On a persistent desk, fatigue is what makes the account a garden, not a puzzle: winners are always dying, exploration is always mandatory, and the explore/exploit dilemma never closes.

---

## 8. Economy

- **Media Budget** (client money, per-day, per-contract): spent on delivery; split across lanes. Wasted spend is the primary skill tax.
- **Agency Cash ($):** retainers + bonuses. Buys shop cards/packs/upgrades, and can **co-invest** in a client's test budget (buying faster significance — cash literally converts to information). The card budget competing with the media budget is the truthy tension.
- **Agency Reserve:** banked cash earns **interest with a visible cap** (Balatro's $25-cap pattern) — the spend-vs-compound discipline check, paid out weekly.
- **Insight:** earned by correct hypothesis calls, correct Diagnoses, and Pins. Spends on dossier un-redactions and one-shot consultant consults ("which gate is leaking, really?").
- **Iteration Points:** duplicate cards auto-convert; IP + a fatigued winner mints the foil V2.
- **Reputation:** the tier gate. Earned on passed reviews and graduations, lost on firings.
- No real-money randomness anywhere. Premium ($7.99–9.99). Pack odds printed anyway, as an EV-literacy device.

---

## 9. Progression, Win, Fail

### Session end
Whenever the player wants. Clean exits at every Day Close-Out (~60s cadence) and Weekly Review (~6 min cadence). Auto-save continuously (snapshot every 5–10s sim time + focus-loss). Optional Overnight Shift arming on exit.

### What persists (everything — it's a desk, not a run)
Card collection (with per-audience wear), live campaign state mid-tick, dossier reveal states, Journal, Playbook rules, cash/reserve/reputation, client contracts and strike counts, shop state, market-director schedule, all PRNG substream states.

### What escalates
1. **Within a contract:** weekly targets ladder up — spend rises, ROAS floor rises, then CPA caps, then diversity minimums ("client wants 3 distinct concepts live"). Diminishing returns to scale do the rest.
2. **Across clients:** tier ladder of fictional mid-tier DTC analogs — Tier 1 boutique (ceramic cookware), Tier 2 regional (western boots), Tier 3 national (basics apparel), Tier 4 whale (multi-audience, fast-decay venue unlock). Higher tiers: more lanes, sparser-combo matrices, harsher fatigue, market-director storms.
3. **Agency Level** (XP from reviews/graduations): unlocks Format slot → Overnight Shift + Playbook → Offer slot + 2nd concurrent client → Modifiers + instant-resolve → 3rd client + Agency Rush challenge mode. Capacity and information speed, never ad power.

### Win
- **Per client:** complete the contract ladder ("Scale Hearthware from $200/day to $5k/day holding ROAS 2.0") → **Graduation**: plaque on the wall, Autopsy, fat bonus, reputation jump.
- **Long arc ("credits roll"):** sign and graduate a Tier-4 client — the desk wall fully lit. Endless mode after, plus a **seeded Weekly Challenge Desk** (separate save, shared seed, excluded from progression) for community play.

### Fail
- **Local:** strikes → firing → Autopsy + salvage. Painful, survivable, instructive.
- **Global (soft):** all clients gone AND cash below the rent line → **Agency Reboot**: the desk goes dark, then relights one tier lower with collection, Journal, and Playbook intact. The closest thing to a run boundary, and even it preserves the knowledge — because the knowledge is the point.

---

## 10. First Ten Minutes (minute-by-minute, brand-new player)

**0:00–0:45 — Cold open.** Dark room. Monitor wall flickers on: SMPTE bars → static → a feed. Phone-buzz haptic; an envelope slides onto the desk: *"FIRST CLIENT: HEARTHWARE — ceramic cookware. Prove yourself: ROAS 1.5 by Friday. $200/day test budget."* Player drag-tears it open (paper-rip haptic). No menus yet.

**0:45–2:00 — First composition.** Six cards fan in (3 Hooks, 3 Visuals), aspect tags visible. Tap = safe inspect (card lifts 1.15×). Tutorial nudges a drag → Light Table slides up with two glowing slots. Player sleeves **"Pan Sizzle ASMR"** (Hook: `sensory 3, curiosity 2`) + **"Kitchen Counter UGC"** (Visual: `trust 2, authenticity 3`) → SLEEVE IT, juice_up punch. One lane available: **New Homeowners (Problem-Aware)** — its dossier almost entirely redacted except *"responds to: trust ▲, ████"*. Drag sleeve to slot: magnetic snap, IN REVIEW stamp.

**2:00–2:20 — Launch.** The ON AIR master lever appears. Slide it (250ms rising haptic + transient). The lamp lights. **Time starts moving for the first time** — the player has already done a full compose-and-deploy before ever seeing the clock.

**2:20–3:30 — Watching Day 1.** Dots stream past the ad. Most ignore it. The first dot *stops* — THUMBSTOP gate flash, tick haptic; Hook Rate odometer stutters up 18%→24% under visible shimmer. One tooltip, total: *"Numbers are guesses until ~50 conversions. Let it run."* First CLICK; first CONVERT rings the register (chip-stack haptic), ROAS odometer appears: **0.84**. The four gate names sit labeled under the funnel the whole time.

**3:30–3:50 — First Day Close-Out.** Desk dips to indigo; overnight whooshes (4s); the Day 1 envelope slaps down. Report: Hook 26% (*"solid"*), Hold 41%, CTR 1.4%, CVR 1.1%, ROAS 0.9, Spend $200. Coaching line: *"People stop but don't click. Where's the leak?"* — first **Diagnose**: player taps a gate; CTR is correct → **Insight +1**, chime.

**3:50–5:00 — Morning Desk, Day 2.** Two new Hook cards deal in. Tutorial: *"Never run one ad. Race two."* Player iterates at the Light Table: same Visual, new Hook — **"Why Your Pans Are Lying to You"** (`curiosity 3, urgency 1`). Pre-launch one-tap: *"Call it: which wins on Hook Rate?"* Player picks. Both sleeves sit in the Test Bench lane, fair split. OPEN.

**5:00–7:00 — Days 2–3: the A/B race.** Two Hook Rate odometers climb side by side under a confidence band reading **TOO CLOSE TO CALL**. The tutorial teaches 2× speed here. Day 3 morning (scripted tutorial seed): **the early leader flips.** Tooltip: *"Day-one leads lie. Wait for the stamp."* Mid–Day 3: **SIGNIFICANT** slams down (shout haptic) — curiosity hook wins, 31% vs 24%. Player called it → **Insight +2**, and the Journal auto-writes its first line: *"New Homeowners: curiosity > sensory for thumbstop."* The dossier un-redacts: *"responds to: trust ▲, curiosity ▲▲."*

**7:00–8:00 — Kill and Iterate.** Verbs unlock with the **Focus meter** (3 pips). Player **KILLs** the loser (drag to shredder — paper-shred SFX, partial budget refund; its cards return to the fan, slightly worn). Player **ITERATEs** the winner (2 Focus): keeps the curiosity hook, swaps the Visual; the clone inherits the hook's learned stats, smaller shimmer.

**8:00–9:00 — Fatigue foreshadow + first threshold ceremony.** The winner's freshness bar visibly ticks down a pixel; Frequency reads 1.8. Tooltip: *"Winners wear out. Watch Frequency — trouble starts near 2.5."* Day 4 close: **ROAS crosses 1.0** — the Wall flashes, jackpot haptic, the desk's first real payoff. Scale tease: *"At 10 conversions on target, this ad can graduate to the SCALE ENGINE."*

**9:00–10:00 — Friday: first Client Review.** Auto-pause; blocking ceremony. The week tallies with eased counters: **ROAS 1.6 vs target 1.5 — PASS** (stamp, retainer counts in, reputation +1). The client raises the bar: *"ROAS 1.8 next week. Here's $350/day."* Shop preview (2 cards + 1 pack). Exit line: *"Your desk is saved — it'll be exactly as you left it. (Keep playing and you'll soon be able to leave it running overnight.)"* The player has now executed the full real loop once: ideate → compose → launch → read funnel → diagnose → race → kill loser → iterate winner — and stands at a perfect exit ramp or a one-tap continue.

---

## 11. Honest Risks (this angle, eyes open)

1. **No run-reset compulsion.** The Balatro "one more run" chemistry comes from resets; a persistent desk leans entirely on fatigue pressure, weekly gates, and seeded client turnover for replayability. If client matrices feel samey, the desk gets "solved" and goes stale. Mitigation: per-client Layer-2 seeding, market director, escalating contract shapes — but this is the angle's existential bet.
2. **Concurrency vs. a phone screen.** The multi-client wall fantasy collides with 2–3 visible lanes and median 3.3-minute sessions. Plate-spinning can smother the data-reading pedagogy in anxiety. Mitigation: hard live caps, event auto-slow, missed-intervention costs bounded to one day — but Two Point pacing on a 6" portrait screen is unproven.
3. **Retention-pattern optics.** A persistent always-there account plus an Overnight Shift *looks* like FarmVille from a distance, even gift-framed with zero decay and no notifications. Premium-educational positioning and App Store/PEGI optics demand we never drift; one bad design meeting away from poison.
4. **Focus meter reads as an energy system.** It is truthy (don't thrash live campaigns) and never monetized, but F2P-trained players may smell stamina. Needs careful framing ("attention," refills every sim-morning, planning always free) and playtest validation.
5. **Playbook rule-builder is a mobile-UX iceberg.** Tap-only boolean rule authoring that stays simple enough for a phone and expressive enough to matter is a real design+engineering subproject; if it ships clunky, the angle's signature mastery system collapses into a settings screen.
6. **Pedagogy pacing without round boundaries.** Autopsies (the big lesson-landing moments) arrive hours apart instead of every 30 minutes. If dossier un-redactions and journal lines don't carry the teaching load between them, learning gets mushy versus round-based rivals.
7. **One precious save.** A persistent multi-campaign sim with deterministic catch-up is a far bigger state machine than discrete flights: save migrations, mid-tick snapshots, and Overnight replay determinism all have to be perfect, and bugs damage a save the player has nursed for weeks. The localfirst discipline (fixture replays in CI, golden hashes) is mandatory, not optional.
8. **Session-arc mismatch risk.** The weekly review arc (~6 min) exceeds the median mobile session; if Day Close-Outs don't genuinely satisfy as exits, sessions feel truncated and the desk feels like homework.
9. **Passivity trap.** Game Dev Story pacing can decay into "watch numbers go up." If the dots/odometers aren't intrinsically pleasurable and Focus under-supplies verbs, OPEN HOURS becomes dead time at 4×. The Wuselfaktor funnel must be prototyped first and killed fast if it doesn't sing.
10. **Tutorial load.** Teaching the metric chain, significance, fatigue, *and* desk management without rounds to chunk the curriculum risks burying new players; the first-hour script needs to gate concurrency hard (one client, one lane, two slots) and trust the ladder.

---

## 12. Timing Reference Card

| Beat | Real time | Cadence |
|---|---|---|
| Sim day (1×) | ~45–60s (overnight auto-skip) | continuous |
| Morning Desk | 30–120s, paused, player-paced | daily |
| Day Close-Out | 8–15s | daily |
| Sim week | ~5–6 min at 1×, ~3 min at 2× | the atomic session arc |
| Weekly Client Review | 30–60s | weekly (per client) |
| A/B race to significance | ~2–3 sim days, budget-dependent | per test |
| Contract (graduation arc) | 6–12 sim weeks ≈ 45–90 min of play | per client |
| Overnight Shift replay | 20–40s digest on launch | when armed |
| Long arc to Tier-4 graduation | ~15–25 hours | once; endless + weekly seeds after |

---

*Companion briefs: docs/research/{engine,balatro,domain,loops,cards,assets,mobileux,localfirst}. This design adopts their constraints wholesale; deviations from the loops brief's round-based Pattern A are deliberate per the mandated angle, with the Overnight Shift promoted from "post-v1" to the angle's signature system (gated behind demonstrated manual play).*
