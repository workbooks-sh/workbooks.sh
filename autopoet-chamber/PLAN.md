# Autopoiesis v3 — the learning system (consensus plan)

## Thesis

v2 (wb-a6u3, shipped) built the autopoet's **constitution and immune system**: it can
sense, propose, validate in scratch, and merge — inside a cage it structurally cannot
escape. What it cannot do is *learn* in any mathematical sense: the brain is a stub and
memory is prose lessons.

v3 gives it a **nervous system**, using only mechanisms validated in this chamber, all
CPU-native, gradient-free, and BEAM-shaped:

1. **Plasticity** (spike 1) — the workspace graph gets weights that strengthen with
   co-activation and decay with disuse. The nexus *remembers its own usage*.
2. **Attention** (spike 2) — a cheap predictor watches the bus; the LLM is called only
   for novelty, and every LLM decision is *installed* as a `.work` rule so it never
   pays cortex price twice. Quality 1.0 at ~1% of always-LLM cost in the spike.
3. **Economy** (spike 3) — components (hooks/rules/agents) hold credit; chains that
   produce rewarded outcomes get paid (episodic profit sharing over event causation
   chains); poor components die, rich ones spawn LLM-mutated variants through the
   existing merge gate. Selection, not backprop.

The intelligence is not any one component — it is the *organization*: pathways that
strengthen, attention that flows to surprise, and an economy that decides what lives.
That is the autopoet as an intelligent server, not a server that calls an LLM.

## Phase 0 — Persist the feedback substrate (prerequisite, small)

Learning eats outcomes; today outcomes evaporate on reboot.

- 0.1 Persist `Nexus.Telemetry` runs to the Store (tenant-partitioned resource, ring
  buffer semantics). `telemetry.ex:135` is in-memory today.
- 0.2 Record per-effect outcomes at the dispatch point: wrap each effect task in
  `Events.dispatch_hooks` (`events.ex:85-100`) with `{status, duration}` → emit a
  neutral `effect.settled` event carrying the causing event's id. This is the single
  biggest missing signal — per-pathway feedback.
- 0.3 Exit: reboot the nexus, history intact; every hook fire has a settled record.

## Phase 0.5 — Realistic testing ladder (shadow-first, zero blast radius)

Validated rung by rung; each rung gates the next. The gym (rung 1) is BUILT and green —
see `gym/run_gym.exs` and the numbers in README/FINDINGS.

1. **Nexus gym** (done): real `.work` corpus, real bus/hook/effect dispatch, shadow
   learners + drift detectors on the delivered stream. This is the tuning arena where
   detector/learner parameters get pinned before touching production.
2. **Replay corpus from production**: capture bus events + agent runs + doc accesses
   from wb-dogfood into a durable, replayable trace (same `.etf` shape the gym writes).
   Converts every future definition dispute into a replay, not an argument.
3. **Shadow learners on the production trace**: prequential scoring only. Go/no-go
   gate: if real traffic shows no hit-rate lift, stop and diagnose before actuators.
4. **First actuator — recall ranking**: weighted spreading activation in SkillKB,
   interleaved A/B vs unweighted. Worst case is slightly worse retrieval; nothing
   mutates, nothing merges.
5. **Brain in proposal-only mode**: typeaway proposer wired, every target `proposed`
   posture — humans accept/reject everything. The accept/reject stream is both the
   safety valve and the first labeled reward signal.

## Cold start — the document is the prior (gym-quantified)

A fresh nexus has no history; the mechanisms cover it in layers:

- **Authored structure = initial synapses.** Edge weights initialize from the docs' own
  parsed refs (prior w≈0.25). Gym numbers: birth-window (first 150 events) hit rate
  0.671 with the prior vs 0.530 blank — +14pt before any learning — while pure static
  structure collapses after drift (0.375) and prior+plasticity holds (0.681). One
  learner dominates the whole lifecycle: born warm, stays adaptive. Cold-start floor
  equals today's unweighted behavior — never worse than v2.
- **Template genomes.** New nexuses are born from templates/toolkits; ship fleet-level
  pretrained weights + reflex-rule libraries with the template (aggregates across
  consenting tenants only — never tenant data).
- **Shrinkage.** Predictors blend `λ·tenant + (1−λ)·fleet_prior`, λ growing with tenant
  volume (empirical Bayes) — smooth handoff from fleet prior to own history.
- **The nursery budget.** Spike 2's amortization curve makes cold start a *priced
  phase*, not a failure: a higher `Inference.Admission` escalation budget for a nexus's
  first N days, annealing down, with ε-exploration annealing on the same schedule.

## Phase 1 — The graph learns (plasticity)

- 1.1 Hebbian writes on the SkillKB edge table (weight column exists, hardcoded 1.0 at
  `skill_kb/graph.ex:38`): on co-activation (refs co-occurring in accessed nodes;
  effects settling against the same event; agent touching docs in one run) bump
  `w += 0.35*(1-w)`; decay lazily at read (`w *= d^Δt`).
- 1.2 Spreading-activation readout in `SkillKB.Recall`/`Graph.expand` (currently
  unweighted 1-hop): rank by activation × weight, 2-hop damped.
- 1.3 Feed recall into the autopoet's SENSE and into agent context assembly (warmer
  pathways surface first — the "building that has learned you").
- Exit / KPI: prequential top-k hit-rate lift over unweighted expansion on real
  workspace traffic (spike-1 shape: expect structure >> none, decay > cumulative under
  drift). Also fix the `@Type` ref-capture gap (`literate.ex:37` requires lowercase).

## Phase 2 — JIT cognition (attention + install)

- 2.1 Bus predictor: one process, decayed-count model of `p(event | prev)` per tenant;
  emits `autopoet.attention` when surprise > θ (adaptive θ, integral-controlled to an
  escalation budget).
- 2.2 Wire the brain: implement `Worker.default_proposer/1` (`worker.ex:178`) as the
  typeaway loop — Groq-class model plans, Mercury-class drafts the `.work` change,
  compile gate + ≤2 repairs. Reuse `typeaway/lib/typeaway/{orchestrator,implementer}.ex`
  patterns; models/keys through `Nexus.Llm` + `Inference.Admission` (real budget).
- 2.3 Install-on-escalation: when the brain handles a novel situation, its output is a
  candidate `hook`/rule unit routed through Eval → Gate → merge → hot-reload. The
  handler cache from spike 2 becomes *literal .work rules* — inspectable, versioned,
  human-auditable cognition.
- Exit / KPI: cost/event amortization curve on a live nexus (spike-2 shape: steady
  state ≪ always-LLM; target ≥10x reduction at quality parity), escalation spike +
  self-quench visible around workload changes.

## Phase 3 — The economy (credit + selection)

- 3.1 Component credit ledger: Store-backed balances per managed hook/rule/agent.
  Income: episodic profit sharing along event causation chains (events already carry
  id/depth) when a REWARD event lands. Outgo: pay-to-act (β-bid per fire) + loser tax.
  Spike-3 lessons are law: episodic (not per-step) credit; explicit ε-exploration.
- 3.2 Reward sources (parameterizable via `.work` config — runtime stays neutral):
  human accept/reject of escalations, `check` units going green, task/todo completion,
  app analytics usage events (wb-a6u3.10), and — in the cloud layer only — billing
  events (Polar) and page-view analytics. "The machine wants to make money" is a
  *deploy-time reward wiring*, not a runtime opinion (the line holds).
- 3.3 Selection: bankrupt managed components are retired (proposal to a human if
  gated); solvent ones periodically spawn 2–4 LLM-mutated variants (typeaway
  multi-option fan-out), evaluated in `Washy.Sandbox`/scratch evals, best-by-credit
  survives. All inside the v2 cage: triad/frozen/ceiling untouchable, leases expire.
- Exit / KPI: fraction of live managed components that are self-produced and still
  solvent after 30 days; interpretability check — sampled surviving rules must read
  sensibly (spike 3's `0# -> 0` standard).

## Compute

This entire program is CPU-shaped. The chamber runs in ~16s on a laptop. In production
the budget currency is **evaluations/sec** (sandbox runs), not FLOPs:

- A 12-core CPU box (Vultr/Hetzner class, ~$70–150/mo) comfortably runs the nexus +
  hundreds of concurrent sandbox evals (washy caps in-flight at 512; ~1.5MB high-water
  per heavy run) + the predictor and plasticity layers (microseconds per event).
- LLM spend is the only marginal cost and is exactly what spike 2 minimizes; it flows
  through `Inference.Admission` so the autopoet has a hard budget by construction.
- Dense by design: plasticity is table updates, attention is a counter model, the
  economy is arithmetic on a small ledger. None of it wants a GPU. Fan-out evolution
  (phase 3) scales horizontally across cheap nodes if ever needed.

## Risks / honesty

- Spike scale ≠ production scale. Each phase carries its own live KPI gate; if the
  lift doesn't replicate on real traffic, stop at the phase boundary — phases 0–1 are
  independently useful infrastructure regardless.
- Reward hacking: mitigated structurally (typed evidence over prose, triad human-gated,
  admission budgets, frozen reward-wiring config), but phase 3 needs an explicit
  red-team pass before any autonomous merge of self-produced rules.
- Protocol collapse (spike 3's failure mode) generalizes: any place selection pressure
  meets a shared vocabulary needs explicit exploration. Budget ε into every selector.
- The Knowledge prose-lesson layer stays — it's the human-readable trace; the ledger
  and weights are the machine-readable learning. Both, not either.

## Appendix — objective definitions (pre-registered)

The discipline for all three: commit the definition before the outcome, score
mechanically, keep raw logs (replay traces) so any metric is recomputable.

- **Drift** = *my own predictor got worse on its own data*: sustained rise in rolling
  prequential surprise, detected by a change-point statistic. Pinned on the gym under
  the committed selection rule (zero stationary false alarms, then min latency):
  **EMA-ratio fast/slow > 1.10 sustained 15 events** (0 FA, 76-event detection;
  Page-Hinkley λ=60 is the qualifying backup at 0 FA / 94 events). Self-referential to
  the model — no labels, no vibes; falsifiable both directions on replay.
- **"What works"** = only pre-registered, mechanically-scored outcomes: `check`
  red→green, Telemetry error rates, task/todo completion, human accept/reject. The
  reward whitelist lives in frozen human-gated config (the cage), so a learner cannot
  redefine its own success. All learners scored prequentially (prediction committed
  before outcome). Goodhart tripwire: a held-out metric basket — monitored, never
  rewarded — alarms when rewarded metrics rise while held-out ones fall.
- **Credit attribution** = structural, never semantic: pay along the runtime-recorded
  event causation chain (id/depth already stamped by the bus). Anti-free-riding from
  both sides: pay-to-act makes chain-stuffing costly, and **counterfactual ablation
  audits** — replay a rewarded chain in the sandbox with one component removed; if the
  outcome stands, its share decays. A sampled Shapley proxy run as a real experiment,
  possible only because this substrate can re-execute reality cheaply.

## Sequencing

Phase 0 is a week-scale chunk. Phases 1 and 2 are independent after 0 and can
interleave; 3 depends on both. Every phase lands behind the existing opt-in
(`Worker.arm/1` is already admin-controlled, default off).
