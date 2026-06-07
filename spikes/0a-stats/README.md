# Spike 0a — the statistics notebook

**The question this spike answers (bd `ad-mqj.1`, roadmap Phase 0a):** can real ad-funnel statistics, time-compressed into a ~3-minute flight, be simultaneously *lively on screen*, *resolvable* (A/B races reach honest significance inside 1–2 flights), and *statistically truthful* (early wobble teaches patience instead of reading as a slot machine)?

**Pass criteria** (docs/04-roadmap.md):
- (a) a meaningful A/B race resolves within 1–2 flights at honest n
- (b) early data visibly wobbles then settles — the peeking lesson reads
- (c) Monte-Carlo shows multiple discovery paths clear a 6-wave run; decision quality dominates noise

**Fail:** no parameter region satisfies all three after honest search → the flight structure in docs/01-game-design.md is wrong; redesign before any engine work.

## How this is built

- **Mocks first** (CLAUDE.md rule 4): `test/` encodes expected behavior — domain benchmarks, determinism guarantees, statistical bounds — before the modules exist. The tests are the spec.
- **Zero dependencies.** Pure Lua 5.1 + the `bit` library (LuaJIT locally ≙ Defold's runtime). The determinism rules (docs/02-technical.md §4) require a hand-rolled PRNG anyway — validating it is part of the spike.
- **`sim/` here graduates to the repo's real `sim/`** if the gate passes. It is framework-free by construction.

## Layout

```
experiments/   the actual notebook — numbered, each prints a self-describing report
```

*(2026-06-05, mock sweep: `sim/` and `test/` graduated to `../simcore/` — one require-tree for all system mocks. Run tests via `luajit spikes/simcore/test/runner.lua`. The experiments resolve modules from there and reproduce their published numbers exactly.)*

## Reference flight (from docs/01-game-design.md)

5 sim-days × 36 s/day × 10 Hz = 1,800 ticks (180 s on screen). $12 CPM. Funnel truth from docs/research/domain.md: hook 28%, CTR/imp 2.2% (⇒ click|stop 7.857%), CVR 2.4% (purchases ÷ clicks), AOV $45.

## Experiment log

| # | Question | Status |
|---|---|---|
| 1 | Is honest event sparsity lively enough on screen, per budget tier? | ✅ **Yes at ≥$200/ad** (buy every ~10s at $400, ROAS lands on the real ~1.95 median). Dead below ~$100/ad (~80s/buy) → wave-1 budget floor is a design constraint. 52 stops/sec ⇒ dots are sampled representatives on screen. |
| 2 | Race resolution sweep: which metrics resolve in ≤2 flights, at what effect sizes? | ✅ **HOOK races pass decisively** (2-pt gap: 91–100% in ≤2 flights at $200+ bench; 4-pt: day 1–2; 0% wrong winners everywhere). **CTR races** need $400+ bench or ≥25% gaps. **CVR races essentially never resolve honestly** (50% gap, $800, 2 flights → 44%) — truthful to reality; design implication: bench races are HOOK/CTR races, CVR/Offer judgments accumulate across waves via Field Notes / Scale-lane volume. That asymmetry IS the curriculum. |
| 3 | Wobble/lead-flip drama vs verdict correctness | ✅ **Bell never wrong (0/720)**; premature call at 10s wrong 16% on subtle races, lead flips after 10s in 27% — the peeking lesson is felt and honest. Drama window scales inversely with gap; bench budget is the race-length dial. |
| 4 | Monte-Carlo run clearability with policy bots | ✅ **RANDOM 38% / HEURISTIC 60% / ORACLE 81%** over 300 seeded worlds — decision quality dominates noise with learnable headroom. Brief ROAS lines = difficulty dial. |

**→ VERDICT: PASS — see [VERDICT.md](VERDICT.md) for locked parameters and design-shaping findings.**
