# Findings — where the mocks talked back

Quantified discoveries from the mock sweep that design should know. These never silently edit `docs/` — each is a measured fact with its design implication, to be ruled on at the pivot review.

## 1. The bell false-positives at ~5-8% on null races (wave machine, 2026-06-05)

Even with the Bonferroni-corrected sequential test (z=2.807, 5 looks/flight), two IDENTICAL ads false-bell a winner in ~2/24 seeds observed (consistent with the family-wise bound). **This is honest statistics** — real ad accounts crown false winners at exactly this rate — but it means the game will occasionally ring the SIGNIFICANCE BELL on a lie.

- Already-designed mitigations that now carry real weight: the **Codex requires replication across 2 separate runs** before canonizing a truth (this is *why*); trust pips buffer noise-driven misses; the autopsy's INCONCLUSIVE grade exists.
- Design question for pivot review: should a false-belled "winner" that later underperforms get an explicit ceremony ("the data lied — replicate before you trust") to convert the frustration into the lesson? The rate is low enough to be a teachable moment, high enough that every long-session player will hit it.

## 2. The learning penalty and the calibration threshold fight each other (shimmer, 2026-06-05)

With a −15% learning-phase delivery penalty applied to the WHOLE funnel, a $400 ad's expected buys-before-calibration drop to ~10.8 against a threshold of 10 — only ~60% of seeds exit learning within one flight. The 0a "calibrates mid-flight day ~3" assumed unpenalized rates.

- **Resolution adopted in the mock (truthful):** the penalty hits delivery quality only — hook and ctr (exploratory delivery = worse audience match) — and NOT cvr (the people who still click convert normally). E[buys] ≈ 12.7/flight → calibration ~day 3-4 typical, but ~20% of $400 ads still finish a flight uncalibrated.
- Design implications for pivot review: (a) an uncalibrated-at-Friday ad should carry its learning state across waves (the bench carry-over has a learning-state sibling); (b) wave-1 budget floors matter doubly — $200 ads essentially never calibrate in one flight (verified; it's the fragmentation lesson, but onboarding must not read as broken); (c) consider counting a click-weighted evidence blend toward calibration if playtests show day-5 shimmer feels bad.

## 3. The funnel needed the HOLD gate (diagnosis engine, 2026-06-05)

The 6-case diagnosis table distinguishes BAIT_AND_SWITCH (stop → don't hold) from NO_REASON_TO_ACT (hold → don't click) — impossible to express on the 4-gate funnel the 0a spike shipped. docs/01 already promised HOOK/HOLD as separate dot-funnel gates; the sim just hadn't modeled it.

- **Resolution:** `hold_given_stop_ppm` added as an OPTIONAL truth field — when absent, zero extra rng draws, so every published 0a number reproduces bit-identically (verified). When present, the dot funnel is the full 5-gate chain and `click_given_stop_ppm` reads as click|hold.
- Ripples to thread at integration (ad-7r3.11): resonance/fatigue/shimmer `apply_to_truth` helpers must pass hold through (and fatigue's staged decay maps naturally: hook→hold→ctr is the real wear order); card content (ad-7r3.9) should give visuals/formats hold-affecting aspects; the 0a race experiments never raced HOLD — bench race classes for hold-rate races inherit the CTR-class budget floors (same denominator: stops ≈ 28% of imps... actually holds races have trials=stops, between HOOK and CTR races in power). *(Passthrough done at integration; hold-side WEAR still deferred.)*

## 4. Skill ceilings scale with content pool size; wear discipline is half the skill (integration, 2026-06-05)

Two results from the grand mock (12-card demo world, 20 seeded engagements):

1. **A pattern-savvy bot that ignores fatigue loses to random.** The first heuristic carried its best combo across the client change and replayed it into combination echo + card wear — and cleared 10/20 vs random's 11/20. Adding only *honest player knowledge* (wear status chips are on screen; new client = retest) took it to 11 vs 6 with harder lines. Pattern-matching without fatigue discipline is worse than diversification — the explore/exploit pressure is mechanically real and pedagogically load-bearing.
2. **Perfect play ceilings at ~55% on a 12-card pool at honest variance.** Oracle ties the good heuristic (11/20): with 2-ad waves, ~17% revenue noise, and only 32 possible combos, the lines that hold random under 30% also cap perfect play near 55%. exp4's 81% oracle needed an 8-hook pool with wide quality spreads. **Implication:** the random≪heuristic≈oracle ordering is robust, but headline clear-rates are a function of content pool size — the real 130–160-card game has the differentiation room the demo lacks; economy tuning must happen against real content scale, not the demo world.
