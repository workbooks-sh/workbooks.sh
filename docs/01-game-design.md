# Game design — the synthesized core loop

> **⚠️ LOOP PIVOT 2026-06-05 (see DECISIONS.md):** live/real-time pacing is dead. The loop is now **turn-based days with Action Points** — plan + act under an AP budget, End Day resolves the market in one sequenced ceremony, weekdays carry traffic identity, brief = one week. The FLIGHT section below describes the superseded live window; the wave structure, all sim math, day-boundary significance, fatigue, pips, and autopsy carry over unchanged. Full revision lands with the skeleton (design/flows.md is the current source of truth for the loop).

**Skeleton:** Campaign Sprint Waves (docs/design/loop-hybrid-waves.md), chosen by author ruling 2026-06-05.
**Tuning law:** game first — the compulsion judge's critiques of this skeleton are mandatory fixes, integrated below and marked `[graft]` with their source.

## 1. Run structure

A **run** is an engagement: a sequence of escalating client briefs survived wave by wave.

- **Default run: "Short Engagement" — 2 clients × 3 waves = 6 waves, ~30–40 min** `[graft: all three designs + feasibility judge independently concluded 9-wave/50–70-min runs exceed mobile session math]`. The full 3-client / 9-wave "Full Book" is an unlock, not the default.
- Every wave boundary is a clean, autosaved exit. The atomic unit a player must finish in one sitting is **one wave, median ≤6 minutes excluding the Newsstand exit ramp** (tightened from the skeleton's 6.5-min median / ~8-min boss ceiling) `[graft: compulsion]`.
- Each client = a fictional mid-tier DTC analog (Copper & Char cookware, western boots, basics apparel) with a brief ladder at 1.0× / 1.5× / 2.0× multiples, rendered as a **visible dollar curve** across the whole run — escalation you can see coming, Balatro-style `[graft: compulsion — hybrid's per-client multiples were "flatter and less visceral" than run-based's $300→$50k climb; show the money]`.
- **Every client's final wave is a boss Launch Week** (hybrid-native — missing any boss = fired): modified market conditions, hard pass/fail. The engagement's last is the hardest.

### Stakes

- **3 trust pips** per run. Missing a regular brief burns a pip + halves the payout; missing a boss Launch Week (or burning all pips) = FIRED. Score-loss-not-run-loss for everything else (the Overcooked lesson).
- **Process protection (v1-simple):** a missed brief where the player ran ≥1 clean test and made ≥1 graded Pin burns the pip but pays a Field-Note bonus — noise with good decisions must never feel like theft `[graft: pedagogy judge's process-grade, shipped at minimum viable size per game-first ruling]`.
- Either ending — CASE STUDY ceremony or FIRED — triggers the **full matrix reveal** so lessons land on failure too.

## 2. Wave anatomy

### BRIEF (~20–30s)
Client target (spend floor + ROAS/CPA line on the dollar curve), market forecast strip, lane dossier (partially redacted — un-redacts as evidence accumulates across the run; **awareness stage and basic traits are never redacted** — they're the prior the player reasons from. Redaction covers only resonance specifics and Layer-2 quirk hints).

### BUILD (paused, ~90s–2min)
- Compose **2–5 ads** from the hand into audience lanes: cards slot as `[Hook] [Visual] [Format] [Offer]` + up to 3 modifiers (see §4).
- **Projection chain is always visible and composes from real definitions:** `$400 @ $12 CPM → 33k imps → HOOK 28% → CTR 2.2% → CVR 2.4% × AOV $45 → ~$790 · ROAS 2.0`, with forecast bands that narrow as Field Notes accumulate. HOOK/HOLD are diagnostic gates upstream of CTR (the same gates the dot funnel renders); revenue always computes as impressions × CTR × CVR × AOV — the displayed arithmetic must actually produce the projection. Multiplicative scheming must be legible *before* launch.
- **Pin hypotheses**: one-tap pre-registration — *"Which wins on Thumbstop?"* — on any A/B pair. Free, graded at autopsy. Every race needs a rooted horse `[native to hybrid; doubled down per compulsion judge]`. (Pins are pre-data discipline; the in-flight CALL IT verb is the opposite act — the names never mix.)
- **The Test Bench** is the designated race lane (fair 50/50 split, hybrid-native). Two benched ads differing by exactly one card earn the **CLEAN TEST badge**. Clean tests do *not* resolve faster (same effect size, same n — the engine never lies about statistics); what they buy is **attribution**: the verdict banks a guaranteed Field Note naming the responsible card/aspect, and clean races get the bell ceremony. `[v1: bench-only; any-lane clean-test detection is deferred depth — §7]` *(Validated by spike 0a: bench races resolve honestly for HOOK at $200+ and CTR at $400+ benches; CVR gaps don't reach significance within waves — CVR/Offer judgments accumulate cross-wave via Field Notes, and bench budget doubles as the race-pacing dial. spikes/0a-stats/VERDICT.md.)*

### FLIGHT (~3 min live, 5 sim days @ ~36s/day)
The ON AIR phase. Time compression per docs/research/loops.md (30–60s/sim-day band, non-uniform: overnight hours auto-skip, peak hours dilate — dayparting taught diegetically).

- **The dot funnel is the spectacle:** customer dots stream past each live ad; some stop (THUMBSTOP gate), hold, click (CTR gate), convert (CVR gate). Gates are labeled with real metric names and live percentages.
- **Per-sim-day chyron stingers** (1–2s: day's spend/revenue delta) chunk the watching into five mini-beats — no 30-second dead air `[graft: compulsion, from live-desk's day close-outs]`.
- **The A/B race** is the flagship: tug-of-war significance meter, early leads flipping often — an emergent property of honest sampling, tuned in Phase 0a (scripted flips exist only in the first-session fixed seed) — then freeze-frame **SIGNIFICANCE BELL** — foil flash, `B beats A +9.2pts (n=2,410)`. Races resolve on sample-size thresholds, never timers; calling a winner early is a felt mistake. Inconclusive at Friday close → **bench carry-over** (accumulated n resumes next wave) `[native to hybrid]`.
- **Intervention verbs** — 4 tokens per ~3-min flight, plus the free verbs marked below; target density ≥1 meaningful decision per ~45s `[graft: compulsion — hybrid's 3-tokens-per-4.5-min was its worst ratio]`:
  - **KILL** — **free, always**: stop a loser, recover remaining budget. Free on purpose (hybrid-native) — the game celebrates a fast kill; charging for kills would teach hoarding tokens while losers burn budget.
  - **BOOST** — shift budget to a leader (diminishing returns apply).
  - **SWAP** — hot-swap one card on a live ad. **This is the deliberately-costed anti-pattern** (the #1 novice sin: editing live ads): the reset is both epistemic (shimmer) *and* a temporary delivery penalty, as in reality. The pro move it contrasts with: compose a variant on the proven body next BUILD, or mint a V2 foil — winners are never touched live.
  - **CALL IT** — free: resolve a race early at current evidence; graded *right / lucky / wrong* at autopsy (decision quality ≠ outcome).
  - **DIAGNOSE** — tap where you think an underperformer leaks: a funnel gate, the FATIGUE chip, or NO SINGLE LEAK (wrong angle). First attempt per flight is free-but-graded (retrieval practice without loss aversion); repeats cost a token, refunded if correct. Offered only once the ad has enough n to be diagnosable — guessing before evidence isn't rewarded `[graft: pedagogy + compulsion, from live-desk — converts watching into a guessing micro-game and IS the diagnostic curriculum]`.
- **1–2 telegraphed director events** per flight from a seeded event table (CPM spike, competitor entry, viral moment) with generous auto-slow decision windows. v1 = weighted table on a drama curve, not an AI director (§7).
- Pause is free, instant, and implied by opening any drill-in panel. Speeds 1×/2×. Auto-pause on background; **no offline progress, ever** (v1).

### AUTOPSY (15s skim, depth on tap)
`[game-first format ruling: never a homework phase]`
- **Skim layer (the 15 seconds):** wave grade vs brief, pins stamped **CONFIRMED / BUSTED / INCONCLUSIVE (n too small)**, one diagnosis headline.
- **Guess-first, never blocking:** before the diagnosis engine speaks, the funnel freezes and offers the guess chips (gates / FATIGUE / NO SINGLE LEAK) — a deliberate chip-tap is graded; any other tap simply proceeds. **The skim never blocks on the guess.** Auto-named for client 1 only, then guess-first forever `[graft: pedagogy — fades worked examples into retrieval practice]`.
- **Depth on tap:** full funnel table per ad, diagnosis sentences from the 6-case rule table (docs/research/domain.md §4 — low hook = first 3s; high hook/low hold = bait-and-switch; high hold/low CTR = no reason to act; high CTR/low CVR = ad-page mismatch; good-then-CPA-rises = fatigue; **all gates mediocre at once = wrong angle/audience — kill and re-concept, don't iterate**), per-card freshness deltas (tired vs wrong — the field's most-confused distinction), Field Notes ledger.
- **Null results auto-bank** as Field Notes ("No detectable Thumbstop lift: Urgency hooks, COLD") — negative knowledge is knowledge `[graft: pedagogy, from run-based]`.
- **Field Notes are the knowledge currency** (one name everywhere — hybrid's "Insights" folds in): confirmed Pins, clean-test verdicts, and nulls bank as Field Notes attached to the aspect×lane cell; they narrow forecast bands on matching compositions and feed the Codex. A Pin on a clean pair resolves to the differing card's aspect — taxonomy-level knowledge; Pins on dirty pairs grade your call but mint nothing.

### NEWSSTAND (~45–60s)
Balatro-shaped shop, restocked every wave `[graft: compulsion — pack-rip frequency matters]`: 2 singles + 2 packs + 1 permanent upgrade. **Card budget and media budget draw from the same bankroll** — the spend-vs-compound tension is the point. Bankroll interest with a visible cap (the Balatro interest mechanic — game-economy only, *not* an economics lesson; the spend floor in every brief is what stops it teaching under-deployment). Skip-shopping banks cash toward a tempo tag.

## 3. Score grammar

Two *diagnostic* axes organize card effects — **ATTENTION** (hook/hold) × **CLOSE** (CTR/CVR/AOV) — but revenue itself always computes from the real chain (impressions × CTR × CVR × AOV vs spend), with **ROAS vs the brief line** as the checkpoint. The ×-tier lives on **visible rare Offers and legendary Modifiers (AOV/LTV multipliers — bundles, subscriptions)** so the shop carries schemable jackpot potential; resonance discovery is the *bonus* multiplier, not the only one `[graft: compulsion, from hybrid's own design — defuses hidden-only-×-tier frustration]`. Real economics, no fabricated "resonance points."

## 4. Card system

Per docs/research/cards.md, adopted wholesale:

- **Grammar:** `Ad = [Hook] + [Visual] + [Format] + [Offer]` in fixed function slots + ≤3 modifiers. **Audience is a deployment lane, not a slot** (mirrors campaign/ad-set/ad). Every card carries 2–4 typed aspect tags (`urgency 3, trust −1`); the ad's summed aspect vector scores against the lane's hidden weights — players learn a *taxonomy*, never card-ID pairings.
- **Onboarding hard gate:** wave 1 = one client, one lane, two slots (Hook + Visual). Format → Offer → Modifiers unlock across the first run `[graft: feasibility, from live-desk]`.
- **Acquisition:** earned currency only. Rarity 70/25/5 + out-of-shop legendaries. Duplicates → Iteration Points; IP + a fatigued winner mints a **foil V2** with a mutated aspect vector (different and fresher, not strictly better).
- **Fatigue:** per-card-**per-lane** wear, staged like reality — thumbstop decays first, then hold, then CTR; onset ~2.5 frequency cold. Visualized as VHS tracking noise on the card art. Rest regenerates; ~3 cycles scar permanently; scarred winners retire into **Learnings** (permanent run-scoped buffs) — loss becomes progression.
- **Fatigue status chips use Meta's literal words:** yellow `CREATIVE LIMITED`, red `CREATIVE FATIGUE`.
- **v1 content budget:** ~130–160 cards (≈38 hooks / 32 visuals / 12 formats / 20 offers / 24 modifiers), 10–12 lanes, 6–10 clients, ~32-aspect taxonomy across 5–6 axes. The taxonomy **is** the curriculum → practitioner review gate (DECISIONS.md, open).

## 5. The hidden-pattern system

Two layers (docs/research/cards.md §5):

- **Layer 1 — global truths, never randomized.** Real advertising heuristics with real signs (Schwartz awareness-stage structure: problem/solution hooks hit cold; testimonials hit warm; offers dominate retargeting; urgency lifts CTR but fatigues faster and erodes trust). This is what the game teaches. Balance may amplify/mute/hide/tax, **never flip**.
- **Layer 2 — seeded per run/client.** Magnitudes, quirks, sparse pairwise combos drawn from audience-archetype priors (the Noita-alchemy precedent: method-knowledge transfers, answers don't). Autopsies explicitly label Layer-2 quirks as *this audience's* quirks so they never discredit Layer-1 lessons.
- **Noise is honest:** binomial wobble that tightens with volume; learning-phase **shimmer** on metrics until ~10 in-game conversions — the compressed analog of Meta's ~50/7d, whose real number lives in the drill-in copy; exact threshold is a Phase 0a output (edits reset it). Waiting for significance is the optimal strategy because it's the true one.
- **The Codex:** canonizing a Layer-1 truth requires confirming it in **two separate runs** — enforced replication, doubling as the curriculum tracker ("14 of 32 patterns confirmed") and the day-7 completionist hook.

## 6. Progression, modes, retention

- **Breadth, never power:** client verticals unlock card sub-pools, lanes, clients, cosmetic foils, Codex pages. Nothing carried strengthens future runs.
- **Modes:** Chill (no-timer) ships in v1. Daily Seed (excluded from progression; offline clock-cheating accepted at no-leaderboard stakes). FM-style **instant-resolve unlocks only after demonstrated learning** — v1 gate: the Codex threshold; the post-v1 Playbook variant (standing orders driving instant-resolve, with rule grading) must re-justify itself. Agency Rush (plate-spinner exam mode) post-v1.
- **Retention ladder (named now so the economy isn't designed for a 3-hour game):** Short Engagement → Full Book → boss-modifier content variety (v1: data for the seeded event table) → Codex completion → daily seeds → per-client stake-style modifier ladder `[post-v1]`. Post-v1 candidates: retained-client scaling mode (macro-skills: budget pacing, diminishing returns), Playbook-lite standing orders gating instant-resolve `[graft: pedagogy, explicitly deferred]`.

## 7. The five bespoke systems — v1-minimum spec

`[feasibility judge: these are hybrid's cost; game-first ruling: ship the smallest version that preserves the wave's identity]`

| System | v1 floor | Deferred depth |
|---|---|---|
| Live sim | 10 Hz fixed-tick, integer state, seeded substreams (docs/02-technical.md) | — (this is the foundation) |
| Ceremony queue | Blocking reveal queue for bell/close/autopsy; never stream the score | More ceremony variety |
| Significance engine | One sequential-test rule tuned in the Phase 0 notebook; powers races, pins, shimmer | Effect-size bands, calibration scoring, any-lane clean-test detection |
| Diagnosis engine | The 6-case rule table + guess-first chips | Prose engine, compound diagnoses |
| Market director | Seeded weighted event table on a drama curve, 1–2 events/flight | Reactive drama engine |

## 8. First ten minutes (sketch — full script in docs/design/loop-hybrid-waves.md, adapted)

Minute 0–1: cold open ON AIR — a pre-built ad already flying, dots flowing; you're asked only to *watch* one gate. 1–3: first Build with 2 slots, 1 lane; the Coach places your first Pin for you. 3–6: first full flight; the significance bell rings your pinned race; first DIAGNOSE prompt (auto-named). 6–7: 15-second autopsy — your pin stamped CONFIRMED; first Field Note banks. 7–9: first Newsstand; first pack rip (ceremony). 9–10: wave 2 brief — the dollar curve and the fatigue bar on your winner are both visible. Deliberately ends mid-climb.
