# Addendum: ON AIR — Balatro-Faithful Run Loop

**Design angle:** Discrete escalating runs. A run = one client engagement. Rounds gate on escalating revenue targets (the "blinds"). Real-time lives *inside* each round as a compressed live flight window. Between rounds: a shop/draft. Roguelite: runs end, knowledge persists in the player's head, meta-unlocks broaden but never empower.

**Optimized for:** compulsion, short sessions, "one more gate."

**Grounded in:** team research briefs (engine/Defold, balatro, domain, loops, cards, assets, mobileux, localfirst). Where this doc conflicts with a brief, the conflict is called out explicitly in §10 (Risks).

---

## 0. One-screen summary

You are a freelance creative strategist. A run is one client account — a fictional mid-tier DTC brand ("Copper & Char" cookware, "Rio Grande Boot Co." western boots, "Plainsong Basics" apparel). The account lasts **8 Sprints**; each Sprint contains three escalating **Gates** (Pulse → Push → Review, mapping Small/Big/Boss blinds). Each Gate is one **Flight**: a 60–120-second real-time compressed market week where you launch ads composed from your hand of cards, watch a funnel of customer dots stop/click/convert, and spend scarce intervention tokens to kill losers, boost winners, and iterate live. Hit the Gate's revenue target → cash → shop. Miss it → fired. Clear Sprint 8's Review → Case Study (win), next client unlocks. Fatigue is the run's natural entropy: your winners wear out, gates grow super-linearly, and the only way through is to learn the audience's hidden resonance patterns faster than your creative decays.

Two visible scoring axes, exactly: **ATTN × CONV** (attention points × conversion multiplier), with a rare ×-tier — **RESONANCE** — earned by matching an ad's aspect vector to an audience's hidden weights. ATTN×CONV is the Balatro chips×mult; resonance is the polychrome.

---

## 1. Run structure (the Balatro skeleton)

### 1.1 The Run = the Account

- Player picks a **Client** (≙ Balatro deck choice). Each client is a fictional mid-tier DTC vertical with:
  - A themed starting deck (~20 cards skewed toward that vertical's sub-pool).
  - 3–4 **Audience Lanes** with hidden resonance weights seeded per run from archetype priors (see §5).
  - A client quirk (≙ deck rule): e.g., Rio Grande Boot Co. — "Heritage brand: Trust aspects +1, Urgency aspects fatigue 25% faster."
  - A signed seed (64-bit) — fully deterministic run, shareable, daily-challenge ready (localfirst brief).
- Run length: **8 Sprints**. Each Sprint = three Gates:

| Gate | Blind analog | Revenue target | Notes |
|---|---|---|---|
| **Pulse** | Small Blind | 1× base | Skippable via **Decline the Brief** → take a Tag (§1.4) |
| **Push** | Big Blind | 1.5× base | Never skippable |
| **Review** | Boss Blind | 2× base + **Market Condition** modifier (§1.5) | Pass = Sprint cleared, sprint cash bonus |

- Gate base targets follow Balatro's curve rendered as client revenue: Sprint 1 base **$300** → Sprint 8 base **$50,000**, super-linear beyond Sprint 8 in endless **Scale Mode**. (Internally integers in cents — determinism rule.)
- **Fail any Gate = fired = run over.** Immediate Autopsy (§5.5). No continues, no revives. Runs are self-contained.

### 1.2 The Round = the Flight (where real-time lives)

Each Gate is resolved by one **Flight**: a compressed market week (Mon→Sun) lasting **90 seconds of wall-clock at 1×** (60s in Sprint 1–2 tutorials, stretching to 120s at Sprint 7–8 where more is live at once). Time controls: pause (free, instant, and implied by opening any metrics panel), 1×/2×/4×. Overnight hours auto-skip; days visibly pulse on a chyron ribbon — dayparting made diegetic (loops brief). Sim runs on a 10 Hz fixed-timestep tick; the tick counter is canonical time (localfirst brief).

Flight resource economy (≙ Balatro hands/discards):

- **Launch slots:** up to **3 ads live simultaneously** (mobileux constraint: 2 slots in early sprints, 3rd unlocked by an Account Upgrade). Each slot is a monitor on the screen's middle band.
- **Launches per Flight: 5** (≙ hands). Killing an ad frees its slot; launching a replacement consumes a launch.
- **Rewrites per Flight: 3** (≙ discards). A rewrite redraws any number of selected cards from your hand at the Draft Desk or mid-flight while paused.
- **Op Tokens per Flight: 4** (the scarce intervention currency, §3.4). Unused Ops pay $1 each at the Close (≙ $1/unused hand).

### 1.3 Economy (the banking skill-check)

One wallet. Media budget and shop purchases compete for the same dollars — the spend-vs-compound tension IS the budget-discipline lesson (balatro + domain briefs).

- Gate rewards: Pulse **$4**, Push **$5**, Review **$6** (+ escalators at later sprints).
- **+$1 per unused Op Token.**
- **Interest: $1 per $5 banked at each Close, capped at $5** (i.e., $25 banked maxes interest). The cap is printed on the wallet.
- Media budget is allocated per ad at launch (budget dial, presets $50/$100/$200 scaling by sprint); spend burns across the flight; **Kill** recovers unspent budget.
- Revenue counts toward the Gate; profit (revenue − spend) does *not* go to the wallet — the wallet is fed by Gate rewards/interest/tags only. This keeps the economy legible and Balatro-shaped rather than a tycoon sim. (Flavor: the client keeps their revenue; you earn retainer fees.)

### 1.4 Decline the Brief (skip tags)

Skipping a Pulse Gate banks tempo for value (≙ Balatro skip tags). Example Tags:

- **Referral** — next shop: one free pack.
- **Focus Group** — immediately reveal one hidden aspect weight of a chosen lane.
- **Dark Social** — next Flight: CPM −30%.
- **Retainer Bump** — +$8 now.
- **Foil Contact** — next pack guarantees a foil.
- **Trend Report** — see next Review's Market Condition early.

### 1.5 Market Conditions (boss blinds)

Each Review Gate carries a rule-warping modifier, drawn seeded-per-run. **Hard design law: a Market Condition may amplify, mute, hide, or tax — it may never flip the sign of a Layer-1 advertising truth** (domain brief: anti-lessons). Examples:

- **CPM SPIKE** — all CPMs +50% this week (efficiency squeeze; teaches CPM-as-attention-price).
- **ANDROMEDA UPDATE** — echo penalty doubled; near-duplicate compositions in the lane crater (encodes the 2026 conceptual-diversity meta).
- **DARK WEEK** — metrics hidden until Day 4 (fly on priors; tests internalized pattern knowledge).
- **TREND CYCLE: URGENCY** — Urgency-aspect cards fatigue 2× this week (amplifies the real urgency-burns-hot truth).
- **PLATFORM AUDIT** — Format slot locked this flight.
- **HOLIDAY RUSH** — CVR +40%, fatigue accrual 2× (volume vs. burnout tradeoff).

### 1.6 Session math

- One Gate (Draft ~60–90s paused + Flight 90–120s + Close/Shop ~60–90s) = **4–6 minutes** with a clean exit at every shop. Atomic loop ≤7 min (loops brief).
- A full run = 17–24 Gates ≈ **45–60 minutes**, chained by deep players, snacked gate-by-gate by commuters. Auto-save at every boundary and on focus-loss; zero offline progress (localfirst brief).

---

## 2. Cards and composition (when and how an ad gets made)

### 2.1 Grammar (cards brief, adopted verbatim)

**Ad = [Hook] + [Visual] + [Format] + [Offer] + up to 3 Modifiers.** Audience is never a slot — it's the **lane** you deploy into.

- Onboarding ramp: tutorial run exposes **Hook + Visual** only; **Format** unlocks at Sprint 3 of the first run; **Offer** unlocks on first run win; **Modifiers** trickle in via packs. After unlock, every run has all slots — slot unlocks are onboarding, not power progression, and they never re-lock.
- Every card carries 2–4 typed **aspect tags** (e.g., `urgency 3, scarcity 2, trust −1`) rendered as icons + numbers on the card face. The composed ad's aspect vector = sum of its parts. Resonance scores that vector against the lane's hidden weights.
- Card frames at the 71×95-px class, 1x/2x atlases, foil/holo treatments double as rarity signals (assets brief).

### 2.2 The two axes (defined before any card — balatro brief)

- **ATTN (chips, additive):** how many people the ad can stop. Hooks and Visuals contribute most ATTN. Drives Thumbstop and impression efficiency in-sim.
- **CONV (mult, additive into a multiplier):** how hard it converts the stopped. Offers and Angle-flavored Hooks contribute most CONV. Drives CTR→CVR in-sim.
- **RESONANCE (rare ×-tier):** when the summed aspect vector aligns with the lane's hidden weights past thresholds, the Close ceremony slams in ×1.25 / ×1.5 / ×2 RESONANT bonuses. This is the pattern-matching payoff and the only ×-mult in the game — discovering resonance is literally how you "go infinite."

Projection at compose time: the assembled ad shows `ATTN 86 × CONV 2.4` with a **confidence band** — wide and shimmering for untested combos, tight for proven ones (learning-phase mechanic, §4.3).

### 2.3 Where composition happens

Composition happens in two places, both paused:

1. **Draft Desk** (pre-flight phase): the deliberate build.
2. **Mid-flight Iterate** (via Op Token): clone a live ad, swap exactly one card from hand, inherit the proven cards' learned stats and a partial freshness reset. This is the modular-iteration workflow practitioners actually use (domain brief) and the game's most skill-expressive verb.

Interaction model (mobileux brief, verbatim): **tap to inspect, drag to commit.** Tap lifts the card 1.15× and shows stats — never spends anything. Drag renders the card 60–80 pt above the finger, drop zones illuminate, magnetic snap within ~64 dp, spring snap-back on miss; tap-to-slot fallback. ≥48 dp fanned hitboxes, ≥56 dp live-play buttons. Haptics per the 10-event vocabulary (pickup tick i0.55/s0.45 → slot snap .rigid i0.8/s0.7 → launch 250 ms rising continuous + transient).

---

## 3. The core loop, phase by phase

### Phase A — THE BRIEF (5–15 seconds, automatic)

The Gate's terms slide in on a CRT monitor: revenue target, days (always 7), any Market Condition, and the lane dossiers' headline VoC quote. One tap to proceed (or **Decline the Brief** on Pulse gates). This is the hypothesis-priming beat: the dossier quote is a planted clue ("I skip anything that looks like an ad" → UGC format prior).

### Phase B — DRAFT DESK (untimed, paused; typically 45–120 seconds)

Screen: bottom 25% card fan (8-card hand), middle ad slots, top read-only lane dossiers + target.

Player verbs:
- **Inspect** (tap card / lane dossier / past-flight notes).
- **Compose** (drag cards into slot scaffolds; partial ads allowed until launch).
- **Rewrite** (spend 1 of 3 to redraw selected cards).
- **Assign lane** (drag composed ad onto a lane chip).
- **Set budget** (dial per ad).
- **Pair for A/B** (place two ads in the same lane differing by exactly one card → the game detects it and awards a **CLEAN TEST** badge: faster significance, insight guaranteed at resolution. Multi-variable mush in one lane gets a gentle **CONFOUNDED** stamp — it still runs, but learn-rate is poor. This is the pedagogy load-bearing wall, §5.2).
- **Launch** (the big red button; consumes a launch per ad; ON AIR lamp + rising haptic).

You may launch 1–3 ads now and hold launches in reserve for mid-flight.

### Phase C — THE FLIGHT (60–120 seconds of market time; the real-time heart)

**What the phone screen concretely shows (portrait, one-handed):**

- **Top fifth (read-only):** chyron ticker — `WK 3 · GATE $1,200 · REV $740 ▲ · THU` — a rolling revenue odometer against the gate target, day-of-week ribbon, Market Condition badge. Never any tap targets here (mobileux).
- **Middle band (~40%): up to 3 monitor slots**, one per live ad, styled as Late-Night Cable master-control monitors (assets brief). Each monitor shows:
  - The **dot funnel** (Wuselfaktor, loops brief): customer dots stream right-to-left past the ad's card-thumbnail; at the **STOP** gate some dots flare and halt (thumbstop made literal), at **CLICK** some shoot downward, at **BUY** they burst into a coin with a register-chunk haptic. Dots that pass without stopping visibly drift off — losers are *seen*, not inferred.
  - **Hero metric:** ROAS, 40–56 pt tabular figures, rolling odometer digits batched into 2–4 visible ticks/second.
  - **Three micro-metrics with sparklines:** Thumbstop %, CTR %, CVR % (real names, always).
  - **Freshness bar** under the card thumbnail + a frequency counter for the lane.
  - **Spend fuse:** the ad's budget visibly burns down the monitor's bezel.
  - Tap any monitor → auto-pause + drill-in panel (full Ads-Manager-style table: impressions, CPM, Hook Rate, Hold Rate, CTR, CVR, CPA, ROAS, Frequency, confidence intervals). The drill-in is where the teaching lives; the glance layer is one number + three meters.
- **Bottom 25%:** the remaining hand fan + four Op buttons + speed control.

**Statistical noise is a first-class citizen:** every metric shimmers (visible static + wide confidence band) until enough impressions accrue; numbers wobble early and settle late. Two ads in one lane run a live **A/B RACE** banner that resolves only at statistical significance — a `SIGNIFICANT` stamp with a thump — never on a timer. The leader is *designed* to flip mid-flight at tuned rates (seeded), so premature winner-calling is a felt mistake (loops brief flagship mechanic).

**Drama curve:** a market-director (RimWorld storyteller pattern) schedules at most one event per flight against a tension curve — a CPM gust, a competitor entering the lane, a mini viral moment — pre-announced 5 seconds ahead with an auto-slow and a generous decision window.

### 3.4 Intervention verbs (Op Tokens, 4 per flight)

| Verb | Cost | Effect | What it teaches |
|---|---|---|---|
| **KILL** | 1 Op | Stop an ad instantly; recover unspent budget; frees slot (relaunching costs a launch) | Kill losers fast; sunk cost discipline |
| **BOOST** | 1 Op | +50% budget to an ad mid-flight | Feeding winners; but boosting pre-significance is the classic noob trap, and the game lets you make it |
| **ITERATE** | 1 Op | Clone a live ad; swap exactly ONE card from hand; inherits proven stats (tight confidence bands on kept cards) and resets ~60% freshness | The real modular-iteration workflow: keep the winning body, swap the hook |
| **SCALE** | 2 Ops | Graduate a significant winner into the Scale Engine: budget burn ×2, winner-take-most revenue, but it now counts against the lane's **diversity meter** — duplicate-shaped follow-ups eat the **echo penalty** | Explore/exploit; Andromeda-era diversity meta |

Pause is always free and never costs anything. Missed interventions cost revenue, never the run by themselves (Overcooked lesson). All UI actions enqueue commands consumed at tick boundaries (localfirst).

### Phase D — THE CLOSE (15–30 seconds, blocking ceremony queue)

The week ends: **"WEEK CLOSED — RESULTS ARE IN"** envelope. The live sim layer (non-blocking) hands off to the ceremony queue (blocking, Balatro-style) — we never stream the score; we *manufacture the reveal* (balatro brief):

1. Per ad: ATTN ticks up with rising-pitch pings as the funnel stages pay out → `× CONV` counts up → **RESONANT ×1.5!** slams in with juice_up punch if earned.
2. Revenue total eases toward the gate target — the near-miss crawl is the compulsion peak.
3. **PASS:** stamp, cash breakdown ($gate + $unused Ops + $interest with the cap shown). **FAIL:** global pitch-drop, FIRED card, straight to Autopsy.
4. Insight bubbles earned this flight (§5.3) re-present for banking into Field Notes.

### Phase E — THE NEWSSTAND (shop; untimed, ~30–90 seconds)

Balatro-shaped, trade-rag styled: **2 single cards + 2 packs + 1 Account Upgrade**, reroll for $5.

- Rarities at 70/25/5 with out-of-shop legendaries (white-whale mechanic). Pack-rip ceremony with earned currency only — zero real-money randomness, odds printed on the pack as an EV-teaching device (cards brief).
- **Account Upgrades** (≙ vouchers, run-scoped): 3rd monitor slot, +1 Op Token, **Research Desk** (reveal one aspect weight of a chosen lane), **Analytics Suite** (confidence bands tighten 25% faster), **Retainer+** (interest cap $5→$8), **Edit Bay** (Iterate resets 80% freshness instead of 60%).
- **Duplicates auto-convert to Iteration Points**; IP + a fatigued winner mints a **foil V2** with a mutated aspect vector — different and fresh, not strictly better.
- Exit shop → next Brief. This boundary is the canonical save/exit point.

---

## 4. Fatigue — the run's entropy engine

Fatigue is why runs end and why one good ad can't carry you (balatro brief: Balatro avoids fatigue only because runs end; our decay is the real-time counterweight — here it does both jobs).

- **Per-card-per-lane freshness bar.** Wear is driven by cumulative impressions × lane frequency. Onset ~frequency 2.5 (cold-audience truth).
- **Staged like reality:** Thumbstop decays first, then Hold, then CTR (domain brief). The dot funnel shows it honestly — fewer dots flare at STOP while CLICK% briefly holds, then everything sags.
- **Meta's literal status words:** the monitor stamps **CREATIVE LIMITED** (yellow) when the ad's CPA runs above its own historical, **CREATIVE FATIGUE** (red) at ≥2× historical. Card art desaturates and develops VHS-tracking shimmer (assets brief). Double dull-knock haptic on each stage.
- **Rest regenerates:** a card left out of play recovers freshness between flights — partial, slower each cycle.
- **Scarring:** ~3 red cycles scar a card permanently in that lane (its ceiling drops there forever this run).
- **Retire → Learnings:** a worn winner can be retired at any Newsstand into a **Learning** — a small run-scoped passive (e.g., "+6 ATTN to all UGC-format ads in Gift Shoppers"). Loss becomes progression *within the run*. Learnings die with the run; across runs they only fill the journal (preserves no-meta-power).
- **Frequency is a lane property:** hammering one lane fatigues everything in it faster — the game's standing argument for audience diversification.

The collision of escalating gates (need more) and fatigue (winners give less) is the run's central dramatic engine and a truthful render of the explore/exploit dilemma.

---

## 5. The pedagogy spine — where hypotheses are formed, tested, confirmed

The teaching claim lives or dies on this chain. Every link is a named game object.

### 5.1 Hypothesis formation — THE DOSSIER (Draft Desk)

Each lane has a dossier: an awareness-stage label using Schwartz's real terms (UNAWARE / PROBLEM-AWARE / SOLUTION-AWARE / PRODUCT-AWARE / MOST-AWARE), two voice-of-customer quotes, and any revealed aspect weights (from Research Desk/Focus Group). Layer-1 global truths are never randomized: problem/solution angles hit cold stages, testimonials hit warm, offers hit retargeting; urgency lifts CTR but fatigues faster and erodes trust; offer dominates CVR; hook dominates variance at the first gate. Per-run Layer-2 seeds only magnitudes, quirks, and sparse pairwise combos drawn from archetype priors. Method knowledge transfers; answers don't (Noita/NetHack model, cards brief).

### 5.2 Hypothesis testing — THE CLEAN TEST (Draft Desk → Flight)

Launching two ads into one lane differing by exactly one card is mechanically privileged: **CLEAN TEST** badge → significance resolves faster and an insight is guaranteed at resolution. Confounded multi-variable tests run fine but learn slowly and can't bank insights. The optimal strategy is literally disciplined A/B testing — not as flavor, as the payoff-maximizing line.

### 5.3 Confirmation/denial — INSIGHT BUBBLES → FIELD NOTES (Flight)

When a test resolves, a tappable insight bubble pops over the monitor (Plague Inc pattern): *"Gift Shoppers: UGC beat Studio Polish on Thumbstop +38% — SIGNIFICANT."* Tapping banks it into **Field Notes**, the in-fiction journal, auto-organized by lane × aspect. Null results bank too: *"No detectable Thumbstop lift: Urgency hooks, New Homeowners."* Negative knowledge is knowledge — the game says so out loud.

### 5.4 Diagnostic localization — THE FUNNEL GATES (Flight, drill-in)

The dot funnel's labeled gates (STOP / HOLD / CLICK / BUY) with live percentages against color-coded real-world benchmarks (Thumbstop 25–30% solid / 30%+ great; CTR ~2.2% median; CVR ~1.6%) train the diagnostic read: low STOP = hook problem; high STOP + low HOLD = bait-and-switch; high HOLD + low CLICK = no reason to act; high CLICK + low BUY = ad-page mismatch (rendered as Offer/lane mismatch); everything fine but CPA rising = fatigue. The drill-in panel names the diagnosis when asked ("Coach hint" toggle, on by default in run 1, off by default after).

### 5.5 The reveal — THE AUTOPSY (run end, win or lose)

Run ends → the full hidden resonance matrix for this client is revealed as a heat-map grid (lanes × aspects), overlaid with your Field Notes: confirmed insights glow, missed weights are circled, false beliefs get a red strike. Headline stats: "You discovered 7 of 12 weights. Your iterations out-earned fresh concepts 3.2:1. Your fastest kill: Day 2." The lesson lands explicitly, then the seed is burned and the next client's matrix is new — only the *method* carries forward. The Autopsy screen is the game's thesis statement.

### 5.6 Progressive disclosure of metrics

Three display modes, player-controlled per panel: **meters only** → **meters + %** → **Terminal** (amber-phosphor full table, Terminal Floor styling). Real metric names at every level: Thumbstop (Hook Rate), Hold Rate, CTR, CVR, CPM, CPA, ROAS, Frequency. Event density runs 10–50× real-world rates while *displayed percentages stay truthful* (domain brief compression rule). Color: Okabe-Ito categorical, viridis continuous, redundant encoding everywhere — never red/green alone.

---

## 6. Win / fail / progression

**A Gate fails when** flight revenue < target at week close → fired → Autopsy → run over.
**A run is won when** Sprint 8's Review Gate passes → **CASE STUDY** ceremony (the client renews; your work gets the foil-stamped trade-rag cover). Optional **Scale Mode** (endless): gates go super-exponential until fatigue and economy collapse — leaderboard food.

**What persists across runs (broadening only, never power):**
- **Client roster:** new verticals unlock (new card sub-pools, new audience archetypes, new quirks). 6–10 clients in v1.
- **Card pool:** unlocked cards join the shop pool for future runs (≙ Balatro joker unlocks).
- **The Casebook:** lifetime Field Notes archive + collection log + per-client best Case Studies + foil cosmetics.
- **Retainer Stakes:** Balatro-stake difficulty ladder per client — White → Bronze → Silver… each raising gate curves, cutting Op Tokens, accelerating fatigue, and (at high stakes) defaulting Dark-Week-style sparse data.
- **Slot/teaching unlocks:** Format/Offer slots and the Coach-off default, as onboarding ramps (one-way, never re-locking).

**What never persists:** stat bonuses, money, cards-in-deck, Learnings, lane knowledge. Every run is self-contained — protecting both replayability and the educational claim (a player who "got good" can prove it on a fresh seed, which is exactly what learning means).

**Session boundaries:** auto-save at every Brief/Close/Newsstand and on focus-loss; app background = hard pause; no wall-clock progress ever (v1). A session can be one 5-minute Gate or a full 50-minute run.

---

## 7. First 10 minutes (brand-new player, scripted seed)

| Time | Beat |
|---|---|
| **0:00–0:45** | Cold open: a CRT monitor wall flickers on. INCOMING CALL — Copper & Char's founder voicemail: *"Agency wants $15k/mo. You're cheaper. Hit my numbers or we walk."* Tap to sign → contract-thump haptic. The first Brief slides in: **GATE: $300 / 7 DAYS.** One lane: NEW HOMEOWNERS (PROBLEM-AWARE) with one VoC quote: *"our pans stick and I'm embarrassed when friends come over."* |
| **0:45–1:30** | Draft Desk, 6-card hand, two slots only (HOOK + VISUAL). Tap a card → it lifts, aspects shown as icons (`urgency 3 · trust 1`). Tutorial asks for one drag: **"Sticky-Pan Confession" hook** snaps in (.rigid haptic). Player picks any Visual freely — first real choice. Ad assembles with a composite flourish: `ATTN 24 × CONV 1.8`, band fuzzy, stamped **UNTESTED**. |
| **1:30–2:00** | Drag the ad onto the lane chip; budget dial preset $50; the big red **LAUNCH** — ON AIR lamp, 250 ms rising haptic, dots begin to flow. |
| **2:00–3:30** | **Flight 1** (75 s, one ad, slowed). First dot flares and stops: *"She stopped scrolling. That's a THUMBSTOP."* Counter appears: **Thumbstop 27%** (meter ticks toward the green 25–30% band). First click whooshes down. First conversion: coin burst + register-chunk haptic; **ROAS odometer rolls 0.0 → 1.4 → 2.3**. Day ribbon walks Mon→Sun; nights blink past. One nudge: *"Numbers wobble early. Watch them settle."* |
| **3:30–4:15** | **THE CLOSE:** envelope; ATTN pings up the funnel, ×CONV counts, revenue eases to **$312 vs $300 — PASS** by a hair (scripted tension). Cash ceremony: $4 gate + $4 unused Ops. |
| **4:15–5:30** | **First Newsstand:** 2 cards, 1 pack, 1 upgrade (greyed, "Sprint 2"). Player has $8; the pack costs $10 — first economic pinch. Buys the "Before/After" hook ($5). Banks $3. Interest meter teases: *"$5 banked = $1 interest."* |
| **5:30–7:30** | **Pulse 2** Brief ($450): tutorial sets up the flagship: *"Two ads. One lane. Change ONE thing."* Player composes the A/B pair (same Visual, two Hooks) → **CLEAN TEST** badge glints. **Flight 2** (90 s): the A/B RACE banner runs; the seeded leader flips on Day 3 — the peeking lesson, felt not told. *"Still settling…"* — then Day 6: **SIGNIFICANT** thump: *Before/After +41% Thumbstop.* An insight bubble pops; tapping it stamps the first **Field Note** into the journal with a satisfying file-drawer shunk. |
| **7:30–8:15** | Close: **$487 vs $450 — PASS.** Interest pays for the first time. Wallet hits $14; the cap is annotated. |
| **8:15–9:00** | Newsstand 2: first **pack rip** — three cards fan, one shimmers **FOIL** (rarity ceremony, shout-class haptic). Choose 1 of 3. |
| **9:00–10:00** | **Sprint 2 Brief:** target jumps to **$800**; a second lane unlocks — GIFT SHOPPERS (SOLUTION-AWARE, different quotes). The proven winner hook now shows a slightly dimmed **freshness bar**: *"Winners wear out. Watch FREQUENCY."* Player drafts into two lanes for the first time and launches. The next clean exit is ~min 12 — but the gate after this one is visible on the chyron, and that's the point. |

Minute 10 leaves the player mid-climb with: one banked insight, one foil, one fatigue warning, a visible escalating target — every compulsion hook and every pedagogy hook set.

---

## 8. Real-time architecture notes (engine compliance)

- **Two queues from day one** (balatro brief): non-blocking live-sim layer (dots, odometers, sparklines) + blocking ceremony queue (Close, pack rips, Autopsy). The score is never streamed — it's revealed.
- Sim = pure framework-free Lua modules; 10 Hz fixed-timestep; integer state (cents/basis points); per-system PRNG substreams from the run seed; command queue at tick boundaries; CI golden-hash test (localfirst brief). Defold is presentation shell only.
- Haptics native extension is week-one work; vocabulary per mobileux table; haptic.play("event_name") abstraction.
- Juice primitives before sim features: T/VT easing, juice_up, shake accumulator, tilt+parallax shadows, per-glyph bouncing text, ease-tweened counters (balatro brief: "they are the product").
- 120 Hz only during card-touch and payoffs; 60 watching; 30 idle; sim decoupled.
- Art: Late-Night Cable direction — the CRT is diegetic (you're watching monitors), ON AIR lamps, chyron tickers, VHS-tracking fatigue dissolve; CRT pass user-toggleable.

---

## 9. Content budget (v1, per cards brief)

~130–160 playing cards (38 hooks / 32 visuals / 12 formats / 20 offers / 24 modifiers), ~32 aspects across 5–6 axes (the taxonomy IS the curriculum — practitioner review pass required), 10–12 audience archetypes, 6–10 clients, ~20 Market Conditions, ~12 Tags, ~10 Account Upgrades. All data-only Lua modules, stable string IDs, Monte-Carlo balance sim in CI.

---

## 10. Honest risks of this angle

1. **Run length vs. mobile session math.** A faithful 8×3 structure yields 45–60-minute runs against a 3–5-minute median mobile session. Gate-level exits mitigate, but Balatro's compulsion partly comes from runs being *almost* finishable in one sitting; ours may feel like a commitment. Fallback: a 4-sprint "Pilot Season" run length as default, 8-sprint as the full engagement — needs playtesting, and shortening weakens the fatigue arc.
2. **Pause may eat the real-time premise.** If optimal play is pause-scrub-decide, the flight becomes turn-based with anxiety; if players don't pause, reflection (the whole pedagogy) suffers. The design bets on scarce Ops + auto-pause-on-drill-in threading this needle; it's the #1 thing to prototype (dots-vs-dashboard spike first).
3. **60–120 s windows vs. statistical lessons.** Significance needs enough simulated events to wobble convincingly; at 10–50× density in a 90 s window, the noise→settle arc may read as either instant (lesson lost) or arbitrary (trust lost). Event-density tuning is load-bearing and unproven.
4. **Roguelite reset vs. learning payoff.** Per-run Layer-2 seeds mean specific discoveries die with the run. If players perceive their A/B work as disposable, the educational fantasy collapses into "RNG with homework." The Autopsy and fixed Layer-1 truths are the countermeasure — but this tension is structural to the run-based angle.
5. **System count at first contact.** Gates + two axes + resonance + fatigue + learning-phase shimmer + interest + Ops + diversity meter is far more simultaneous rule surface than Balatro's. The slot/coach onboarding ramp helps; still the highest overwhelm risk among possible angles.
6. **Two-axis abstraction vs. funnel truth.** ATTN×CONV is a Balatro-legible compression of a five-stage funnel; if the compression visibly contradicts the drill-in metrics (e.g., resonance ×mult with no funnel correlate), we teach a false model. Resonance must always be *explained* in funnel terms in the drill-in.
7. **Market Conditions can teach anti-lessons** if a modifier ever reads as "urgency is bad now." The amplify-don't-flip law needs enforcement in content review, not just intent.
8. **Balatro-like saturation.** By late 2026 the "Balatro of X" lane is crowded; this angle leans hardest into the comparison, which sharpens the pitch but invites direct quality comparison with a masterpiece on feel — a solo-dev juice bar that is genuinely expensive to clear.
9. **Economy degeneracy.** Resonance is the only ×-tier; if discovery is gated behind lucky early tests, late gates become unwinnable without it and runs die to hypothesis variance, which players will read as slot-machine RNG — the exact anti-lesson we must avoid. Needs Monte-Carlo verification that multiple discovery paths clear Sprint 8 at target win rates.
10. **Revenue-vs-wallet split legibility.** "Gate revenue isn't your money" is clean once learned but is a non-obvious economy rule that contradicts tycoon instincts; first-session confusion risk, mitigated by the retainer fiction.
