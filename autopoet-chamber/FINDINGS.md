# Findings

Four spikes, deterministic seeds, run 2026-07-01 on a laptop (Elixir 1.19.5 / OTP 28).
Total runtime ~16s. Every number below is reproducible via `./run.sh`.

## Spike 1 — Hebbian plasticity on the workspace graph

Simulated workload: 240 docs, 12 latent task-paths, zipf task selection, insertion/skip
noise, 24k access events, **regime drift at 12k** (half the tasks replaced). All learners
share the same spreading-activation readout; only the plasticity rule differs.

| learner | warmup | pre-drift | post-drift | settled | recovery to 90% of pre |
|---------|--------|-----------|------------|---------|------------------------|
| hebb (η=0.35, decay 0.9985) | 0.734 | **0.783** | **0.748** | **0.788** | **500 events** |
| counts (normalized, no decay) | 0.726 | 0.757 | 0.686 | 0.760 | 622 events |
| freq (global top-3) | 0.167 | 0.172 | 0.154 | 0.159 | — |
| recency | 0.004 | 0.008 | 0.007 | 0.006 | — |

Read:
- **Structure is the big win** (0.78 vs 0.17 floor). Any edge-weighted graph beats none.
- **Plasticity buys adaptivity**: hebb wins everywhere, and the gap widens exactly where
  it should — right after drift (+6.2pt) — with faster recovery. Decay sheds stale pathways.
- Instrument lesson (kept honest): the first run's counts baseline collapsed because raw
  counts blow up the 2-hop spreading term. Normalization fixed the *harness*, not the claim.

## Spike 2 — Surprise-gated cognition (JIT-compiled cognition)

Regime-switching event stream (40 types, 4 regimes, p(switch)=0.0025), reflex cost 1,
cortex (LLM) cost 200. Two gates, cleanly separated: a **competence gate** (cache-exact:
do I have a handler for (ctx, event)? miss → escalate → cortex's answer *installs a
handler*) and a **surprise channel** (−log₂ p̂, attention/anomaly only).

| policy | quality | cost/event | vs always | escalation |
|--------|---------|-----------|-----------|------------|
| always-cortex | 1.000 | 200.00 | 1.000 | 100% |
| reflex-only (top-3 predictor) | 0.645 | 1.00 | 0.005 | 0% |
| **escalate-on-miss + install** | **1.000** | **2.56** | **0.013** | **0.8%** |

Cost curve per 5k-event window: `6.89 → 1.48 → 2.55 → 1.96 → 1.88 → 2.95 → 1.32 → 1.48`
— early windows pay for "compilation", steady state approaches reflex cost; bumps are
regime switches. 133 live handlers at end (TTL-bounded memory).

Anomaly channel: surprise-escalations run **4.7x** above steady state in the 60 events
after a regime switch, then self-quench. Attention flows to novelty and dies back.

Read: **quality 1.0 at 1.3% of always-LLM cost.** This is the economics of the autopoet
brain: the LLM is the motor for *novel* situations; every decision it makes should
materialize as an installed `.work` rule so its next occurrence is reflex-priced.

## Spike 3 — Economic credit assignment (ZCS / bucket brigade)

**Mode A — Wilson ZCS on the 6-multiplexer** (the classic LCS benchmark, chance 0.5):
rolling accuracy **0.970** at 20k episodes. The strongest evolved rules are correct AND
interpretable — e.g. `1###00 -> 0` ("address bits 1#: both selectable data bits are 0,
answer 0") is a maximally-general correct multiplexer rule the economy discovered on
its own. Wealth spreads across the correct rule set (top decile holds 12%), i.e. no
degenerate monopoly.

**Mode B — two-layer chain, credit only from the final outcome.** Layer 1 sees the 6-bit
input, may only emit a 2-bit message. Layer 2 sees ONLY the message, answers 0/1. Reward
touches only the chain outcome.

- **Strict per-step bucket brigade: FAILED — sat at chance for 48k episodes.** The message
  protocol collapsed (2 of 4 messages died; the survivors carried no information) before
  layer 2 could assign semantics. Kept in the file header as a design lesson.
- **ε-greedy (0.10) + episodic profit sharing (Grefenstette 1988): 0.947 accuracy.** The
  layers *invented a 1-bit protocol*: P(answer=0 | msg∈{00,01}) ≈ 0.96–0.97,
  P(answer=1 | msg∈{10,11}) ≈ 0.95, and layer 2's strongest rule reads `0# -> 0` —
  decode the first message bit, ignore the second.

Read: outcome-only economic credit **can** build internal communication pathways with no
gradients — but the credit scheme must be *episodic* (pay whole chains on outcome), not
per-step bid-passing, and exploration must be explicit. Both lessons transfer directly
to paying hook/agent/rule chains from `Nexus.Events` causation chains.

## Spike 4 — Production-parser probe (no simulation)

`Nexus.Literate.parse/1` over realistic `.work` source: every node carries `:refs`
(`[[backlinks]]`, `#tags`, `:atoms`, `work://`), hooks parse as code units, and applying
spike 1's exact Hebbian bump to ref co-occurrence yields a weighted mini-graph
(repeated co-activations strengthen: 0.35 → 0.577). **The parser-native signal for the
plasticity layer already exists in production; only persistence is missing.**

Gap found: the ref regex (`literate.ex:37`) requires lowercase after `@`, so `@Order`
(types are capitalized by convention) creates no graph edge. Filed as follow-up.

---

# Gym tier (realistic, through production paths) — run 2026-07-01

**The gym** (`gym/run_gym.exs`): 40 real `.work` docs (parsed by `Nexus.Literate`), 2
real hooks (compiled by `Nexus.Hook` from `gym_hooks.work`), 8,076 events through the
real `Nexus.Events.emit` → Task.Supervisor → `Effects.run` path. 100% effect
settlement, latency p50 3µs / p99 12µs / max 255µs. Stamping (id/at/depth) intact on
every delivered event.

Shadow learners on the **delivered** stream (not generator intent):

| learner | birth(150) | coldstart(800) | pre-drift | post-drift | settled |
|---------|-----------|----------------|-----------|------------|---------|
| hebb_prior (authored refs) | **0.671** | 0.686 | 0.701 | **0.681** | 0.673 |
| hebb_blank | 0.530 | 0.672 | 0.702 | 0.681 | 0.673 |
| counts | 0.503 | 0.655 | 0.691 | 0.521 | 0.651 |
| static_only (prior, frozen) | 0.691 | 0.658 | 0.656 | 0.375 | 0.411 |

**The document is the prior** (+14pt at birth over blank) and **plasticity keeps it
alive** (static collapses to 0.375 post-drift). One learner dominates the lifecycle.

**Drift detector sweep** under a committed rule (0 stationary false alarms, then min
latency): pinned **EMA-ratio 1.10 sustained 15** — 0 FA, detects true drift in 76
events (PH λ=60 qualifying backup: 0 FA / 94 ev).

**Capture prototype** (`gym/capture.exs`): framed append-only trace through the real
bus — 2000/2000 round-trip, 98 B/event (≈100MB per million events). Production-ready
loop; only the deploy wiring (a supervised subscriber in the cloud layer) remains.

**Replay harness** (`gym/replay.exs`): learners + pinned detector over any `.etf`/
`.etfs` trace. On the gym trace: reproduces learner numbers; detector fires exactly
once at event 4076 (76 after true drift), zero false alarms. Harness lesson promoted
into the pinned definition: drift must be relative AND material — the detector carries
an absolute floor (fast-EMA > 1.0 bit), else near-deterministic streams (mean surprise
0.127 bits) alarm on any rare symbol.

**Real-corpus prior harvest** (`gym/real_corpus.exs`, this repo): 303 `.work` files,
**0 parse failures**, 76.2% ref coverage, 50,850 distinct co-activation edges. Two
signal-quality findings that shape the production prior:
- Raw refs are 94% `:atom` mentions dominated by enum values (`:ok`, `:low`,
  `:moderate`) — stopword-like. Prior must weight by ref class + idf.
- `#tag` capture is polluted by CSS hex colors from styled blocks (`#fff`, `#aee5c2`)
  — parser hygiene gap (with the `@Type` lowercase gap, filed as wb-mdk4.9).
- Clean navigation prior (`[[backlink]]`/`#tag`/`work://`, hex-filtered): 652 distinct
  edges over 31.4% of files, sensible hubs (`[[overview]]`, `#go`). Usable but thin →
  production recipe: navigation edges full weight + idf-discounted atoms + SkillKB
  embedding-similarity edges as densifier.

# Integration map — where each mechanism attaches to Nexus

What exists, what's missing, with anchors (verified against the tree 2026-07-01).

## Feedback substrate (what learning eats)

| Signal | Where it exists today | Gap |
|--------|----------------------|-----|
| Per-agent-run outcome (turns, tokens, latency, status) | `Nexus.Telemetry.record/2`, called at `agent.ex:303` | **in-memory only** (GenServer state, `telemetry.ex:135`); reset on reboot |
| Per-wasm-run outcome (ok/trap/timeout, fuel, latency) | `Nexus.Washy.Metrics` (`:counters`, metered per shell run at `shell.ex:131`) | in-memory only |
| Per-effect outcome (did the hook's effect succeed? duration?) | **does not exist** — `Events.dispatch_hooks` (`events.ex:85-100`) is fire-and-forget; crashes only logged | the biggest single gap: no per-pathway feedback |
| Drift → concerns | `Nexus.Telemetry.concerns/1` (`telemetry.ex:75`) — already the autopoet's SENSE input (`worker.ex:110`) | fine as-is |

## Spike 1 attaches: the weighted graph

- Ref signal: parser-native (`literate.ex:37-59`, every node's `:refs`) — proven by spike 4.
- Durable weighted edges: **already exist** in `Nexus.SkillKB.Graph` — `Edge` rows via
  `Store.create` with `%{src, dst, kind: :backlink, weight: 1.0}` (`skill_kb/graph.ex:38`).
  The weight column is there; **nothing writes anything but 1.0**. The Hebbian rule is a
  drop-in: bump on co-activation events, decay lazily at read.
- Readout: `SkillKB.Recall` (cosine top-k) + `Graph.expand/4` 1-hop fan-out
  (`skill_kb/graph.ex:51-69`) — currently unweighted expansion; spike 1's spreading
  activation slots in here.
- Co-activation source: `Nexus.Events` bus (`events.ex:104-120` pub/sub) + store writes
  (`store.ex:80-91` emits on `#event`-tagged resources).

## Spike 2 attaches: the attention/JIT layer

- Predictor: a subscriber process on the bus (`Events.subscribe/1` exists).
- "Install a handler" = the autopoet writing a `hook`/rule `.work` unit through the lane
  that already exists end-to-end: `Eval.validate/2` (scratch) → `Gate.classify/3`
  (triad authority) → FIFO-merge → hot-reload (wb-a6u3.7, per-turn perms re-resolution).
- Real cost accounting: `Nexus.Inference.Admission` (the money boundary, `admission.ex:16-39`)
  + `Pricing` registry — the spike's cost-200-vs-1 becomes real dollars.
- Scheduler has **no priority dimension** (`scheduler.ex:53`, flat `{tenant, name}` map) —
  the natural seam for attention-weighted scheduling.

## Spike 3 attaches: the economy

- Causation chains already exist: events carry `:id`, `:depth`, causation (`events.ex:69-74`,
  depth-capped at 8) — the "chain" that episodic profit sharing pays.
- Account/ledger primitives: `Inference.Admission` (per-tenant credits/caps),
  `Nexus.Ledger` (signed metering attestations as git notes), `Tiers`/`Capacity`
  (compute units). **Missing: per-component (hook/rule/agent) credit balances** — a new,
  small, Store-backed table.
- Variant generation (the GA analog): typeaway's proven two-model loop — Groq plans
  structure, Mercury drafts `.work`, compile-gate + ≤2 bounded repairs
  (`typeaway/lib/typeaway/{orchestrator,implementer,loop}.ex`), multi-option fan-out
  (`multi_option.ex:12-53`), each option a real jj-committed workbook. This is the
  mutation operator, already built and tested (43 tests) one repo over.
- Selection arena: `Washy.Sandbox` / `Nexus.Shell.run/3` — 512 concurrent in-flight cap
  (`shell.ex:154-171`), ~1.5MB high-water per heavy run, cells/GB density tracked.
  Evaluations/sec is the budget currency.

## The brain (the stub to fill)

`Nexus.Autopoet.Worker.default_proposer/1` → `:skip` (`worker.ex:178`). The proposer
contract is already injectable: `fn item -> {:ok, %{relpath => new_src}} | :skip`.
Typeaway's loop IS this function with the item rendered into its prose slot.

## Constraints the user asked about (already built — do not rebuild)

"Moral qualities that can't be edited" = the v2 constitution: structural triad
{grant, ceiling, management} human-gated at the merge gate (`gate.ex`), `frozen`
agents untouchable, ceiling = intersection of ancestor `index.work` ceilings so
self-escalation is **structurally impossible** (widening requires editing an ancestor
index above the write-scope). The learning layer lives entirely *inside* this cage:
it adjusts weights, credits, and managed rule bodies — never the cage itself.
