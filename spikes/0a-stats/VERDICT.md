# Spike 0a — VERDICT: **PASS** (2026-06-05)

The existential question — can real ad statistics, compressed into a ~3-minute flight, be simultaneously lively, resolvable, and truthful — has a **yes**, with quantified parameters and three design-shaping findings. The flight structure in docs/01-game-design.md survives contact with the math.

## Gate criteria

**(a) A meaningful A/B race resolves within 1–2 flights at honest n — PASS.**
HOOK races: a subtle 2-pt gap resolves 91–100% within 2 flights at $200+ benches (4-pt gaps: day 1–2), **0 wrong winners in 8,400 simulated races**. CTR races need $400+ benches or ≥25% relative gaps. CVR races do *not* resolve honestly (see finding 2). (exp2)

**(b) Early data wobbles then settles; the peeking lesson reads — PASS.**
The bell was wrong 0 times in 720 rings. Calling the raw leader at 10s on a subtle race is wrong 16% of the time with lead flips after 10s in 27% of races — premature calling is a felt, measurable mistake while the bell stays perfect. (exp3)

**(c) Decision quality dominates noise over a 6-wave run — PASS.**
RANDOM 38% / HEURISTIC 60% / ORACLE 81% clear rates over 300 seeded worlds (avg pips retained: 0.6 / 1.0 / 1.6). Monotone separation with learnable headroom between heuristic and oracle. Brief ROAS lines are the difficulty dial. (exp4)

## Locked parameters (feed sim/ and docs/01-game-design.md)

| Parameter | Value | Source |
|---|---|---|
| Flight clock | 5 sim-days × 36 s × 10 Hz = 1,800 ticks | validated throughout |
| Event-density inflation | **None needed** at reference budgets | exp1 |
| Wave-1 ad budget floor | ~$200/ad (below ~$100 the screen goes dead: ~80 s/buy) | exp1 |
| Significance looks | day boundaries; family α 0.05 over 10 looks (2-flight carry-over) → per-look z = 2.807 | exp2/3 |
| n_min | 200/arm on the raced denominator | exp2 |
| Bench floors | $200 (HOOK races), $400 (CTR races) | exp2 |
| Race pacing dial | bench budget (smaller bench ⇒ longer race arc, honestly) | exp2+3 |
| Shimmer threshold | ~10 conversions ≈ mid-flight day 3 at $400/ad (17 buys/flight) — consistent with design doc | exp1 |

## Design-shaping findings

1. **Sparsity was the wrong fear; budget floor is the real constraint.** Honest rates at $400/ad: buy every ~10 s, 4 clicks/s, ROAS ≈ 1.95 (lands on the real-world median — strong sanity check). At 52 stops/s, display dots must be sampled representatives (a rendering choice, not a stats lie).
2. **The Test Bench is a HOOK/CTR instrument; CVR is a cross-wave judgment.** Even a brutal 50% CVR gap at an $800 bench resolves only 44% over two flights — true to real media buying. CVR/Offer evidence must accumulate across waves (Field Notes / Scale-lane volume). The top-funnel-fast / bottom-funnel-patient asymmetry is now a *mechanically true* curriculum, not a scripted one.
3. **Drama scales inversely with effect size — and that's correct.** Standard (-4pt) races are settled in seconds; subtle (-2pt) races carry multi-day arcs. Blowouts should look like blowouts; bench budget tunes the spectacle length without touching honesty.

## Methodology validated

Mocks-first worked: 41 tests encoding domain benchmarks + determinism guarantees were written before the modules and all passed on first full run. Zero dependencies (pure Lua 5.1 + `bit`, LuaJIT ≙ Defold semantics). `sim/rng.lua`, `sim/funnel.lua`, `sim/flight.lua`, `sim/significance.lua` are graduation candidates for the real `sim/`.
