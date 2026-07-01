# Assumption ledger — binary resolution (2026-07-01)

Every assumption from the v3 program is classified exactly one of:
- **(a) FACT** — resolved decisively by a local experiment or code read (confirmed OR
  refuted; a negative result is still a fact), or
- **(b) PRODUCTION HYPOTHESIS** — cannot be resolved locally; carries a pre-registered
  test spec (hypothesis, instrument, metric, threshold) that production must run.

No gray area. Experiments live in `gym/` (`real_traffic.exs`, `envelope.exs`, `bench.exs`).

## (a) Resolved to facts

**A1. "Real usage has exploitable structure" → FACT: CONFIRMED.**
37,281 real file-touch events from this repo's commit history (real developer traffic,
not synthetic): hebb top-3 hit rate 0.320 overall vs 0.011 frequency floor — 29x lift.
Pre-registered rule (hebb ≥ 2× floor) passed by 15x margin.
*Sub-fact with teeth:* no-decay counts (0.345) beat hebb (0.320) on this stream — real
repo history drifts slower than the gym's decay horizon. **Decay rate is a per-stream
tunable, not a constant.** (`gym/real_traffic.exs` E1)

**A2. "Authored links are a usable birth prior" → FACT: REFUTED.**
The authored `.work` backlink graph (201 resolvable file→file edges) tested against the
real co-edit stream of those same files (711 transitions): static-prior birth(150) hit
rate **0.020 vs 0.201 blank-hebb** — the pre-registered ≥5pt rule failed catastrophically
in the opposite direction. The gym's +14pt birth advantage was by construction (corpus
links were generated from the task paths). Authored links help only marginally as a
*component* (hebb_prior 0.413 vs hebb_blank 0.380 overall). **Cold start cannot lean on
authored structure; the recipe must lead with template genomes + embedding similarity
(wb-mdk4.8 updated).** (`gym/real_traffic.exs` E2)

**A4-linkage. "Causation chains are reconstructable" → FACT: REFUTED (known 1-line fix).**
The `emit` effect passes only `depth` + `tenant` (`effects.ex:50-52`); chained events do
NOT carry the causing event's id. Chains cannot be reconstructed today. Phase 0 adds
`cause: event[:id]` at the emit effect + dispatch ctx. (code read)

**A5. "Detector parameters transfer across drift shapes" → FACT: envelope measured.**
24 runs (severity × shape × 3 seeds), pinned detector (EMA 1.10×15 + 1.0-bit floor):
- Abrupt drift ≥25% severity: reliable, fast (119 ev @25%, ~30 ev @≥50%).
- Gradual drift: slow (1,024–4,749 ev) and unreliable in the mid range; 25%-gradual
  effectively missed (1/3 seeds).
- False alarms are NOT zero in general: up to 4 per ~5.5k stationary events (~0.07%).
  The gym's "0 FA" was one stream, one seed.
**Production reading: an alarm means "workload changed at least this much"; silence does
not certify stability; alarms are investigation leads at a few per 10k events.**
(`gym/envelope.exs` E3)

**A6. "It scales" → FACT: CONFIRMED, large headroom on a laptop.**
Real bus + 500 registered hooks: 23,293 events/s (42.9 µs/event incl. linear-scan match
+ supervised task dispatch), 100% settlement. Learner at real graph scale (16,387 nodes):
5.4 µs/event, 186k events/s single-process, 4.6 MB graph. Capture: 319k events/s,
28.9 MB/s. Headroom vs a generous 1k events/s production bus: 23x / 186x / 319x.
(`gym/bench.exs` E4)

## (b) Production hypotheses — pre-registered specs

**B3. Installed handlers stay correct (staleness).**
- Hypothesis: fleet-median cortex-disagreement of installed handlers < 2% at 30 days.
- Instrument: audit sampling — p=2% of handler-served events also escalate to cortex in
  shadow; record agreement in the ledger.
- Pre-registered action: a handler with >5% disagreement over ≥50 audits is auto-retired
  (proposal filed to re-learn it). No threshold tuning after data arrives.

**B4. Episodic credit separates good from bad components on real chains.**
- Precondition: A4-linkage fix shipped; proposal-only mode (wb-mdk4.7) has produced
  ≥100 human-labeled (accepted/rejected) proposals with recorded causation chains.
- Hypothesis: profit-sharing credit computed over recorded chains ranks components such
  that AUC(accepted vs rejected participation) ≥ 0.7.
- Below threshold: credit design iterates; NO autonomy while below.

**B7. Incentive integrity (Goodhart / free-riding).**
- Resolved boundary (analysis, not assumption): LLM-bearing chains are non-replayable by
  construction → ablation audits apply only to deterministic components (rules/hooks/
  wasm); LLM components are audited at outcome level (B3's mechanism).
- Hypothesis: the defense stack (frozen reward whitelist, pay-to-act, ablation audits,
  held-out metric basket) survives a red-team suite — chain-stuffing, reward-event
  spoofing, prompt-injection into proposals — with 0 successful credit exploits, AND the
  held-out basket alarm fires on an injected Goodhart scenario.
- Gate: passing this suite is a hard precondition for any autonomous merge (phase 3).

**B8. Fleet priors transfer to cold tenants.**
- Forced to (b) by evidence: local workspace repos contain only empty-tree jj keep refs —
  tenant content history exists ONLY server-side (`real_traffic.exs` E5).
- Hypothesis: leave-one-out over ≥20 consenting production tenants: fleet-prior
  birth(150) beats blank birth by ≥5pt.
- Negative result is actionable fact: genomes must be artifact-level (template-shipped
  rules/weights), not path-level.
- Nursery budget is POLICY, not an assumption — shipped behind an A/B (nursery vs flat
  budget; compare 30-day acceptance rate and cost).

**B9. The composed system is useful.**
- Instrument: proposal-only mode (wb-mdk4.7) — the autopoet proposes real edits with
  real evidence; humans gate everything.
- Hypothesis (30 days): acceptance rate ≥ 40%, rising trend (week 4 > week 1), zero
  structural-triad violations, cost within the nursery budget.
- Below threshold: the brain/proposer iterates; the composed claim fails fast and
  visibly. This is the top-level experiment the whole program reports to.

## Score

Five assumptions resolved to facts locally (two confirmed, two refuted, one bounded as
an operating envelope). Four carry pre-registered production specs. The two refutations
(A2, A4-linkage) already changed the design — cold-start recipe rewritten, Phase 0
gained the `cause` stamp — which is the point of the exercise.
