```markdown
# Ether Training Corpus & Agentic-Alignment Plan

Status: inked (v2 — adversarial-review pass folded in). Supersedes the corpus sketch in `corpus-plan.workflow.js`. Builds on `ETHER-PLAN.md` (model, host, Phase 0→1→2 pipeline), `TRAINING-STRATEGY.md`, `INFERENCE-VIA-TRAINING.md`, `MODEL-SELECTION.md`. Reads the workponents etch-out as ground truth: the **3-element spine** (`work-src`/`work-ref`/`work-flow`), the machine-readable contract (`custom-elements.json`, `registry/*.json`, `theme-contract.json`), the lint seam (`src/validate/design-lint.js`), the theming skill (`skills/theming.md`).

**Two corrections folded in up front:**
1. **Granite-4.1 dense (3B/8B/30B) is a pure transformer, NOT Mamba-hybrid** — the "Mamba × llama.cpp pinning" risk in `MODEL-SELECTION.md` applies to the 4.0-H line only and is **dropped**.
2. **The catalog count is unresolved in the live tree and must NOT be hard-coded.** `ls registry/*.json` = **57**; `registry/index.json#totals.components` = **52**; the spine tags `work-src`/`work-ref` have **no `registry/*.json` at all**; `work-flow.json` exists but `work-flow.js` lives in `src/elements/flow/`, not `work/`. The earlier "52 tags / 54 hidden" framing was wrong on its own substrate. **Reconciling this spread is a P0 prerequisite (§8 P0c); no guardrail may assert a literal element count until then.**

---

## 1. THESIS

We are training Granite-4.1-3B to BE a **catalog-grounded, contract-reading, full-service workbook agent** — not a component emitter. Its durable competence is a *procedure*: discover what exists → read the contract slice it was handed → compose spine + visual elements against ONLY that slice → bundle/build → read the error → fix → ship → tell the user what happened, honestly. The specific tags, `--work-*` tokens, and per-element variant enums are the **target of in-context grounding, not rote recall**. They are a moving, machine-maintained source of truth supplied at inference as a prompt-cached contract slice.

**Verdict: COMPOSE-grounded, with eyes open about what the weights absorb.** Fine-tuning installs format/skill reliably and new facts unreliably (LIMA superficial-alignment; FT-teaches-format-not-facts). A catalog with per-element attributes/events/tokens is a pile of low-frequency facts — the first thing catastrophic forgetting eats, and a permanent re-tune treadmill since the catalog *just moved once already* (`work-*` pile → spine + prefixed toolkits). The catalog is already machine-readable; we do not want it as the *primary* store in the weights.

**Honest caveat (was overclaimed — see §2.3).** Gradient descent on thousands of catalog-grounded examples WILL absorb the trained catalog as a strong prior; we do not pretend otherwise. The claim we defend is narrower and falsifiable: **read-then-use generalizes to structurally-novel, unseen-schema elements supplied only in-context** — proven by the novel-schema held-out gate (§2.2, §9), not asserted. The "tenant's totally bespoke catalog, zero re-tune" line is a **hypothesis under test by that gate**, not a guarantee.

The economic argument — that the catalog can move in-context without re-tuning, exploiting prefix-cache reuse on the serve box — is real but bounded by the actual llama.cpp slot-cache behavior on a single-slot CPU box (§7-serve); we quantify it there rather than citing an uncited "220×."

---

## 2. WHAT LIVES IN WEIGHTS VS IN-CONTEXT — and the new-verb mechanism (the centerpiece)

### 2.1 The split

**In WEIGHTS (stable format/skill — the right fine-tune target):**
- **Spine grammar** — `<work-src lang=…>` (inline source IS the body), `<work-ref rel=…>` (every edge: dependency, binding, AND type), `<work-flow>` (the DAG; pure presentation, host fires it). Nesting contracts, "what something IS is an edge not an element," composition-as-source. Syntax — stable, durably installable.
- **Theming discipline** — style ONLY from `--work-*` tokens (never raw hex/rgb/hsl), variants ONLY from declared enums, `em`/`%`/`clamp()`/`color-mix()` are the legal exemptions, lint-before-done. A procedure (`skills/theming.md`), not a palette.
- **The agentic loop shape** — orient → discover → read-contract → compose → bundle → `work build`/lint → read-error → fix → ship → assist.
- **The read-then-use reflex** — "when you need an element/verb you don't recognize, go read its registry/contract slice FIRST." The keystone meta-skill.
- **Edge-as-type reflex** — express "this is a skill/agent/toolkit" as `<work-ref rel="skill|agent|kit">`, never invent a `<work-skill>` tag.

**In CONTEXT (volatile facts — supplied at inference, prefix-cached):**
- The tags + per-tag attributes/events (`registry/index.json`, `registry/<tag>.json`).
- The `--work-*` tokens + roles + types (`theme-contract.json#tokens`).
- The per-element variant enums + defaults (`theme-contract.json#variants`).
- The `rel=` kinds, the `lang` lane routing, the `from=`/binding contract.
- A tenant's bespoke catalog (the product story — under test, §2.3).

### 2.2 The mechanism: contract-in-prompt SFT (RAFT/RAT-shaped)

This is the load-bearing technique. The literature is the *right shape* — not "already solved."

- **RAFT (Retrieval-Augmented Fine-Tuning).** Train on `(task, [relevant slice + distractor slices], answer that cites the slice verbatim)`. Every composition example's prompt includes the `registry/<tag>.json` slice(s) the answer uses, PLUS 2–4 distractor element slices, PLUS the relevant `theme-contract.json#variants[tag]` + `#tokens` slice. The target composes against ONLY the relevant slice and references its declared attributes/tokens/variants verbatim. The model learns the *operation* "ground generation in the provided contract."
- **Gorilla RAT (the evolving-API precedent).** Gorilla fine-tunes WITH the retrieved API doc in-prompt and adapts to *argument/version evolution of APIs whose doc-format it trained on*. That is the precedent for our moving-catalog problem — **but note its scope:** it tracks evolving args of known-shape APIs, it does NOT demonstrate zero-shot composition of structurally-novel elements with unseen attribute schemas. Our tenant-catalog claim goes *beyond* the Gorilla result, which is exactly why §2.2's **novel-schema held-out gate** is mandatory rather than assumed.
- **Example-grounded fallback (depends on P2 `example` backfill, §8).** When a contract slice is thin, include ICL-demonstration examples ("here are two uses of an unfamiliar `prefix-*` element, produce a third"). **This fallback is only as good as `example`-field coverage, which does not exist today and is a hard P0 deliverable (§8 P2-A, §11.1). If coverage < 100% of injected tags, this fallback degrades silently to attribute-name-only grounding — we measure coverage as its own gate.**

**The held-out gate — TWO tiers, the novel-schema tier is PRIMARY.** The single self-fulfilling-eval trap is to withhold 20% of *our own* elements whose attribute grammar, token namespace, and naming convention are identical to the trained 80%, then call passing it "learned a new verb." A model that memorizes "fill attributes from the slice, draw colors from `--work-*`" passes that without any OOD capability. So:

- **TIER 1 — Novel-schema held-out (PRIMARY, the COMPOSE proof).** A dedicated set of **≥ 40 hand-authored synthetic-future elements** with *genuinely novel attribute shapes* — different prefixes (`acme-*`, `tenant-*`), attribute names/value-types not in the trained vocabulary, and at least some with a token namespace distinct from `--work-*` (supplied in-slice). Composed given ONLY their contract slice. **This is the keystone bar: ≥ 80% lint+build pass.** It is the *only* tier that proves the tenant-catalog thesis. It gets its own count budget (§3 shape K) and its own gate.
- **TIER 2 — Same-family held-out (SANITY CHECK, demoted).** Withhold ~20% of the shipped elements from training *answers* (still allowed as in-context distractors). Passing this is necessary but not sufficient — it is a regression tripwire, **not** the generalization proof. No commercial claim rides on it.

**Vary the contract presentation** across examples — full slice / minimal slice / slice + 2 distractors / slice + sibling-prefix slices — so the skill is not welded to one prompt shape.

### 2.3 The memorize/compose tension is real — corpus design must actively fight it

48% of the corpus (shapes A+B+C) composes over our own catalog; gradient descent on that WILL bake the shipped catalog into the weights regardless of the in-context slice. Tier-2 held-out cannot detect this. Two mitigations, both adopted:

1. **Rotate the in-context-only set across epochs.** No single shipped element gets a stable, memorizable answer-frequency: each epoch, a rotating ~30% of elements appear *only as in-context slices* (never as the answer), so the model cannot converge on a fixed per-element answer distribution. This forces the read-then-use path even on familiar tags.
2. **The novel-schema tier (§2.2 Tier 1) is the real OOD detector** — it cannot be satisfied by catalog memorization because the schemas are not in the training answers at all.

We **explicitly accept** that the shipped catalog ends up partially in the weights, and reframe the durable claim accordingly: *compose generalizes to adjacent and novel catalogs supplied in-context, proven by Tier-1, not by the absence of catalog priors.* The thesis is the generalization, not weight-purity.

---

## 3. CORPUS COMPOSITION — task shapes with target %

Target the corpus at **a per-shape minimum-viable count**, not a single round headline — the "LIMA-scale" intuition (a narrow domain with a hard executable gate is quality-bound) holds for the *format-installation* shapes (A/B/C/D) but is **misapplied to the judge-gated conversational shapes (H/I) and the multi-skill load overall**. We are installing **seven distinct skills** (spine grammar, theming discipline, the loop, read-then-use, CLI verb grammar, fix-lane recovery, anti-fabrication) — LIMA installed *one* (format alignment over a base that already had the knowledge). So we budget per-shape and plan an explicit **expansion round** rather than defending a single number.

**Per-shape minimum-viable table** (cold-start SFT set; counts are floors, expansion round adds where evals are thin):

| # | Task shape | Floor count | % (≈) | Source | Gate |
|---|-----------|------------:|------:|--------|------|
| A | **Catalog-grounded composition** (RAFT-shaped, distractors) | 780 | 22% | registry-synthetic | usage-lint + CEM-tag + enum + render |
| B | **Spine usage** (`work-src` lang routing; `work-ref` rel-kinds; `work-flow` DAG) | 490 | 14% | registry-synthetic + teacher | structure parse + render |
| C | **Discovery-then-compose** (same-family unseen-tag slice → emit; Tier-2 read-then-use) | 420 | 12% | registry-synthetic (held-out) | enum + tag-in-given-slice |
| D | **CLI / work-verb tool-use** (single + chained) | 455 | 13% | grammar-synthetic from `cli.ex` + teacher | verb exit-code |
| E | **Bundling** (`work bundle`/unbundle round-trip, when-to-bundle) | 245 | 7% | teacher + grammar-synthetic | `work verify`/build pass |
| F | **Bash-equivalent compute** (`shell`: ls/cat/jq/grep/pipes; NOT native exec) | 280 | 8% | teacher-distilled | exit-code + output check |
| G | **The fix lane** (compose → lint/build → read REAL error → re-compose; multi-turn) | 420 | 12% | teacher + logs-only | error→pass transition |
| H | **Research-to-source** (`web_search`→`fetch`→compose with real numbers) | **300** | 8% | teacher-distilled | judge (real data, no fabrication) |
| I | **Assisting / communication** (narrate, honesty/false-premise, `file_issue`, carry-on) | **300** | 8% | teacher + logs-only | judge |
| J | **General-instruction replay** (anti-forgetting) | **see §7-J: tied to measured IF-drop, NOT a fixed 2%** | — | held-out general SFT set | — |
| K | **Novel-schema held-out eval set** (PRIMARY generalization bar, §2.2 Tier 1) | **≥ 40** | eval-only | hand-authored synthetic-future | Tier-1 gate |

**Note the rebalance from the draft:** shapes H and I are raised from 5% → 8% each. They are judge-gated *conversational* skills that need MORE data, not less; 175 each (the old 5%) is below viable for honesty/false-premise robustness. The floors above sum to ~4,160 pre-dedup; after dedup expect ~3,500 surviving, with the **expansion round explicitly budgeted** to backfill any shape whose §9 eval lands under bar (most likely H, I, and Tier-1).

Synthesizability classes (drives sourcing, §4):
- **Fully synthetic-from-registry (A, B-spine, C, D-single):** generated from `registry/*.json` + `theme-contract.json` + `cli.ex` grammar + **`lintUsage` as the label generator (P3 — does not exist yet, §8/§4)**. ~60% of the surface, zero logs needed *once P3 lands.*
- **Teacher-distilled (B-flow, D-chains, E, F, H, happy-path of G/I):** Claude Code CLI driven through real end-to-end tasks; MiniMax-M3 for bulk volume.
- **Logs-only (messy tail of G, dead-ends, assist texture, long-horizon under compaction):** harvested over time (§6). Bootstrapped by the teacher.

---

## 4. DATA SOURCES & THE TEACHER SPLIT

### 4.1 Registry-synthetic (the floor — BLOCKED on P3 `lintUsage`, see §8)

> **HARD DEPENDENCY:** step 3 below auto-labels with `lintUsage(html, contract)`, which **does not exist today** — `design-lint.js` exports only `lintElementSource`, `lintThemeContrast`, `designLint` (all lint element *source*, not workbook HTML *usage*). Synthetic generation **cannot begin** until P3 ships AND its precision/recall is measured against a hand-labeled set (§8 P3, §5). A low-recall labeler silently admits garbage positives; low-precision discards good data.

Recipe — `ether/corpus/gen_synthetic.exs`, per example:
1. Pick a target tag from the **reconciled** index (§8 P0c). Pull its `registry/<tag>.json` slice + its `theme-contract.json#variants[tag]` enum + `#tokens` role map. Pick 2–4 distractor slices **from the same domain prefix** (§11.2 — random distractors are too easy).
2. Render the prompt as a realistic task PLUS relevant + distractor slices inline (RAFT shape).
3. Generate the target answer (valid attribute set, in-enum variant, token-only styling) — OR have a cheap model fill it — and **gate through `lintUsage` + the enum-join preflight (§5)** so only contract-clean answers become labels.
4. Tag with `slices_in_context: [<tag list>]` (the held-out-eval + flywheel join key — see §8 P-traj for the provenance it requires).

For **Tier-2 held-out:** exclude ~20% of shipped tags from being *target answers* (still appear as in-context slices). For **Tier-1 (shape K):** hand-author the novel-schema set separately (§2.2). For **CLI grammar (D-single):** enumerate `cli.ex`'s verb tree → `(task, correct verb+args)`. For **lint preference pairs:** generate deliberately-flawed compositions, run `lintUsage`, keep `(flawed, lint-errors, corrected)` triples.

### 4.2 Claude Code CLI trajectories (the teacher)

Drive Claude Code CLI through REAL end-to-end tasks on the exact 12-tool agent surface (`agent.ex`). Record in the SAME `_steps.jsonl` / `_trajectory.jsonl` shape the runtime emits **(after P-traj lands — `slices_in_context` is not emitted today, §8)**. Claude's runs naturally contain the error-recovery, discovery-dead-end, and assist behaviors that are otherwise logs-only. The teacher's terseness is the label (tight jump-to-region → minimal edit → build).

**The teacher carries 100% of the fix-lane (shape G) signal until organic success-rate clears a measured threshold (§6).** This is not a stopgap to apologize for — a cold-start 3B will not produce hard error-recovery trajectories that pass an outcome gate, so the teacher *is* the fix-lane source by design until the fleet proves out.

### 4.3 MiniMax-M3 (bulk pattern volume)

Cheap bulk coverage of synthesizable classes at scale across the catalog × task types × contract-presentation variations. Every output passes the same hard gate (§5); non-survivors are discarded or become preference negatives.

### 4.4 Real logs (the flywheel — §6)

Highest-weight for the fix lane, dead-ends, assist quality — **with the cold-start correction in §6 so the flywheel does not starve on the signal it needs most.**

---

## 5. THE GATE — deterministic machine-lint as rejection-sampler

Every example passes a hard gate before entering the corpus. The gate IS the auto-label for structural pass/fail.

> **PREFLIGHT (must pass before the gate can run on any tag):** **contract-completeness check.** Variant enums live in `theme-contract.json#variants` while registry `attributes` are bare names (`["variant","size","tone","disabled"]`) — the enum gate must JOIN two files per tag. Given the 57/52 registry/index mismatch, some registry tags will have NO `variants[tag]` block. **Assert: every registry tag carrying an enum-shaped attr (`variant`/`tone`/`size`/…) has a corresponding `theme-contract.json#variants[tag]` entry; FAIL the build otherwise.** Without this, gate #2 has undefined behavior on the gappy tags (crash, or silently pass everything — the exact "silent off-enum fallback" it claims to catch).

**Deterministic (no judge — the bulk):**
1. **CEM-tag-existence** — every emitted tag exists in the **reconciled** index (§8 P0c). Invented tags rejected.
2. **theme-contract enum conformance** — every `variant`/`tone`/`size`/… value ∈ `theme-contract.json#variants[tag]` (after the preflight join guarantees the entry exists).
3. **`lintUsage(html, contract)`** — **(P3, does not exist yet)** — `off-token-color` (raw hex/rgb in inline `style=`), `off-system-value`, `unknown-token`, `unknown-attr`, `variant-conformance`, `missing-required-binding`, `contrast`. Stable `{path,rule,message}` shape feeds the fix-lane as turns. **This is distinct from the shipping `lintElementSource`, which lints element SOURCE, not the workbook HTML the model emits.**
4. **`work build` / tangle / render** — workbook parses (Floki `tangle_plan`), `work-src` bodies tangle (requires §8 P0b — the tangler matches `work-component` today, so a `work-src` workbook tangles to NOTHING and this gate silently passes empty), page renders headless without console errors.
5. **CLI exit-code** — verb returned 0 with expected structural output.

**Judge-needed (gemini LLM-judge, the conversational tail):**
- Assist quality / honesty / false-premise (shape I).
- "Used real fetched data, did not fabricate" (shape H).
- ~~Render fidelity vs. the canonical `example` (vision judge)~~ — **DEFERRED. Vision is out of scope per prior decision; the render-fidelity vision-judge is dropped as a gate. Render correctness is covered by the deterministic gate #4 (build + render-no-console-error), which needs no vision model.** (See §9.)

The deterministic gate is the cheapest high-quality corpus signal **pre-logs** — *once P3 exists and its recall is measured.*

---

## 6. THE LOGS FLYWHEEL

**The substrate already exists for telemetry — but the SFT-grade capture does NOT.** Every exec agent run (`agent.ex`) already emits at the chokepoint: `_steps.jsonl` (tool/args/output truncated to 200B), `events.html`, `_telemetry.db`, `Ledger`. **None of these record `slices_in_context` — which registry slices were in the prompt — and that is the flywheel's join key (used by both the held-out eval and distillation).**

> **`slices_in_context` is a real host plumbing task, NOT "wire a harvester."** The injected contract IDs flow from `work_kits.ex` injection into the prompt; recording *which* slices were in context per turn means threading those IDs through the agent loop into the log. The injected prefix is prompt-cached — **verify the slice list is even recoverable per-turn post-hoc; if it is not, it must be emitted at injection time.** Scoped as §8 **P-traj** with its own effort estimate. The flywheel does not turn until P-traj lands.

**The loop:**
1. **CAPTURE.** Add `_trajectory.jsonl` — the verbatim untruncated assistant turn + tool result + `slices_in_context` (P-traj). Gate the full copy to opted-in tenants (it can hold user data).
2. **GATE.** (a) **outcome gate** — ended in `done` with verifiable success (lint clean, build passed, `publish`/`verify` returned a live URL); (b) **judge gate** — gemini on assist/honesty; (c) **privacy gate** — tenant opt-in + secret-scrub. Local-only, never committed (beads canon).
3. **DISTILL.** Winning trajectories → SFT examples `(task, slices_in_context, full tool sequence, final answer)`.
4. **FEED.** Next round mixes synthetic + harvested. The catalog stays in-context, so a catalog rev never invalidates the model.

> **COLD-START CORRECTION — the fix-lane must NOT be outcome-gated (the draft's fatal flaw).** A cold-start 3B on a hard agentic loop has a LOW final-success rate, so the highest-value error-recovery trajectories — shape G, weighted highest — are exactly the ones that DON'T end in `done`+live-URL and would never enter the corpus. The flywheel would harvest only easy wins and starve the hard tail. **Fix, adopted:**
> - **Decouple fix-lane harvest from the outcome gate.** Capture *recovered* failures — an error→eventual-pass transition *within a run* (a lint/build error that later cleared) — **regardless of final task success.** The transition itself is the label.
> - **The teacher (Claude-CLI) carries 100% of fix-lane signal** until organic success-rate clears a measured threshold (target **> 40%**). We do not pretend shadow runs are organic.
>
> **Shadow runs are NOT organic logs.** Running the bootstrapped model on existing eval packs in "production-shadow mode" produces the *same synthetic distribution wearing a costume* — useful for seeding the harvester and exercising the gate, but they are not real user tasks and are labeled as synthetic, not organic. The "logs flywheel turns from day one" claim is true only for the *machinery*; the *organic* signal accrues with real traffic.

---

## 7. TRAINING PIPELINE (fold into Phase 0 → 1 → 2)

**Base:** `ibm-granite/granite-4.1-3b` (Apache-2.0, pure dense transformer, 128K ctx). **Primary trainer:** Unsloth (first-class Granite-4.1, fixed chat templates + GGUF). LLaMA-Factory `granite4` template = backup; TRL = the preference substrate.

### Phase 0 — corpus build & gate (§3–§6)
**Ordering is gated by §8:** reconcile the catalog (P0c) → build `lintUsage` + measure its recall (P3) → backfill `example` to 100% coverage (P2-A) → THEN generate the synthetic floor → teacher-distill the logs-only classes → gate everything → per-shape-floored, deduped corpus + the **Tier-1 novel-schema eval set (shape K)** + a general-replay set. **Hard hygiene gate: web-component-only — org-mode denylist is non-negotiable (org is deprecating).**

### Phase 1 — QLoRA-SFT
IBM Granite Snack Cookbook recipe (`FineTuning_with_Unsloth.ipynb`), base → `granite-4.1-3b`:

| Knob | Value | Delta vs cookbook |
|---|---|---|
| `target_modules` | all 7 (q,k,v,o,gate,up,down) | — |
| `r` / `lora_alpha` | 16 / 16 | — |
| `lora_dropout` / `bias` | 0 / none | — |
| `load_in_4bit` | **True** | cookbook 16-bit; 4.1 dense is QLoRA-safe |
| `max_seq_length` | **8k–16k** | cookbook 2048; trajectories + slices are long |
| `learning_rate` | 2e-4 | — |
| `num_train_epochs` | 2–3 | stop on eval-loss plateau (avoid catalog memorization) |
| batch / grad-accum | 2 / 4 (eff. 8) | — |
| `optim` / `wd` / sched | adamw_8bit / 0.01 / linear | — |

Chat template: Granite's own — `<|start_of_role|>…<|end_of_role|>` + `<|end_of_text|>`; tool calls `<tool_call>{json}</tool_call>`, tool results `<tool_response>`. **Pass tools via `apply_chat_template(..., tools=[…])`; do NOT hand-roll the tools system prompt.** `llm.ex` needs a dedicated **Granite recovery branch** (NOT Qwen's XML dialect).

### Phase 2 — length-penalized preference-opt (RL = NO)
**ORPO** (ref-free, single-stage, length-normalized) default; **SimPO** to dial the length penalty harder. Avoid plain DPO (frozen ref, length-drifts).

> **CORRECTNESS AND LENGTH ARE TWO PREFERENCE SETS, NOT ONE (the draft conflated them and would teach length-hacking).** Binding "shorter passing vs longer/failing" into a single signal means the model cannot tell whether it was rewarded for being *correct* or for being *short* — it learns "shorter is better" unconditionally, including on genuinely hard tasks that need more reasoning, and predictably learns to skip the lint/build self-check to save tokens. **Adopted split:**
> - **Correctness pairs:** passing vs failing, **length-matched** (control for length so the gradient is pure correctness).
> - **Length pairs:** both passing, shorter preferred (pure length gradient, only where correctness is held equal).
>
> - **Lazy length penalty** still applies on the length set: penalize length **only on CORRECT trajectories, only beyond a tolerance band, only after training stabilizes**, and **exempt verified tool-call turns** (only penalize prose/emit verbosity) so the multi-step fix lane is never truncated. Documented: 27–77% token cut for ≤1–4% accuracy loss.

### Phase 2.5 — on-policy distillation (the forgetting cure, reserved lever)
NOT RL. If pref-opt plateaus OR forgetting appears: distill the served model on its own recent on-distribution failures, graded by the teacher. ~9–30× cheaper than RL; restores IF-eval 85→45→83. Doubles as the catalog-rev refresh. **Gate strictly on a measured forgetting signal (general-replay eval drop > 5%) or a plateau — never speculative.**

### Phase-J — anti-forgetting budget tied to the measured drop, NOT a fixed 2%
The old fixed 2% (~70 examples) is too thin to defend the base model's general instruction-following across THREE training stages — especially given Phase-2.5 exists *because* forgetting is expected. **Adopted:** the general-replay fraction is **set from the measured IF-eval drop**, not a constant. Start at 5%, measure IF-eval after each stage, and raise the replay fraction (and/or trigger Phase-2.5) whenever the drop exceeds the §7-Phase-2.5 threshold. The replay budget is a control loop, not a magic number.

### Serve — Q5_K_M on llama.cpp (CPU, bare-metal)
Merge adapter (`save_method="merged_16bit"`) → `convert_hf_to_gguf.py` → `llama-quantize … Q5_K_M` (3B ≈ 2.44 GB, fits the $11/mo box). Gotchas: **`--jinja` mandatory**; **train↔serve chat template + EOS byte-identical**; serve greedy (`temp 0, top_p 1, top_k 0`); **no Mamba-pinning** (dense) — replace with a smoke-test of the exact GGUF on the exact `llama-server` build before committing the box.

> **PROMPT-CACHE ECONOMICS — the "220×" claim is dropped (uncited, and incompatible with the serve substrate).** llama.cpp prompt caching on CPU is **prefix-reuse of the KV cache for a single ongoing session/slot** — it is NOT the multi-tenant, cross-request prompt cache that API providers offer (where a "220×" figure would originate). On a single-core, single-slot box, **a moving per-tenant contract prefix evicts on every tenant switch and must be re-prefilled.** The corrected economic argument:
> - The cached-prefix win is **real within a tenant session** (the contract prefix is reused across that tenant's successive turns).
> - It is **NOT a stable cross-tenant cache** on this box; per-tenant cold requests re-prefill the contract.
> - **Quantify before relying on it:** measure prefill cost of the contract slice on the target box; if cold re-prefill dominates, the "compose-not-memorize is free at serve" argument weakens and the slice must be kept small (which §8 P1/P2 already drive toward) or tenants pinned to slots. The compose thesis stands on *correctness/maintenance* grounds (DRY, catalog-churn survival) independent of the cache claim.

---

## 8. SYSTEM FIXES (shrink the corpus + raise reliability + align around memory)

Ranked by leverage. **P0* are hard prerequisites for ANY corpus work.**

| # | Fix | File | Effort | Prereq? |
|---|-----|------|--------|---------|
| **P0** | **Drop the `work-` prefix filter** — `work_kits.ex:342` gates injection on `String.starts_with?(tag, "work-")`, injecting only the spine tags and hiding the visual catalog. Gate on `d["customElement"] && d["tagName"]`, or read the allow-list from the reconciled index. | `runtime/host/work_kits.ex` | 30 min | **YES** |
| **P0b** | **Audit & decide the `work-component` ↔ `work-src` migration — NOT a one-line tag match.** `workbook.ex` is `work-component`-coupled across `component?/1` (line ~209), `validate/1`, world-detection (`top_flows`/`flow?`), `comp_of`, and `tangle_plan`. The runtime's whole *structural model* is still `work-component`-based, while the spine compute element is `<work-src>`. A `<work-src>` workbook is **not discovered/compiled today** — so §5 gate #4 silently passes empty. **Deliverable:** audit every `work-component` reference, decide the migration story (match `work-src` AND keep `work-component` for back-compat, or migrate), and pin which element model the corpus trains against. The structural contract is currently *ambiguous between two element models* — that ambiguity must be resolved before generating training data. | `runtime/host/workbook.ex` | **~0.5 d (was "1 h")** | **YES** |
| **P0c** | **Reconcile the catalog count — the guardrail cannot assert a literal.** Live tree: `ls registry/*.json` = **57**; `index.json#totals.components` = **52**; `work-src`/`work-ref` have NO registry JSON; `work-flow.json` exists but its `.js` is in `flow/`. **Decide the single source of truth** ("indexed components" vs "registry files" vs "CEM customElements"), reconcile the 57/52 spread, and write the P0 guardrail against the *reconciled* number — `catalog count == <reconciled SoT>`, NOT a hard-coded `52`/`54`. | `registry/index.json`, `tools/registry.mjs`, guardrail test | ~0.5 d | **YES — guardrail reds day one otherwise** |
| **P1** | **One canonical index + discovery verb.** Make the reconciled `registry/index.json` THE index; inject from it. Add the **missing spine entries** (`work-src`/`work-ref` registry JSON) + a `kind` field (`spine\|visual\|lib`). Add `work components [show <tag>]` returning index + contract slice — the deterministic discovery entrypoint a logged trajectory calls. | `work_kits.ex`, `registry/index.json`, `tools/registry.mjs`, `cli.ex` | ~1 d | prereq for shape C |
| **P2-A** | **Backfill `example` to 100% coverage — HARD P0, gates §4.1.** The `example` field **does not exist** in the registry today (confirmed: `auth-gate.json`/`work-button.json` have `attributes/events/cssVars/tokens/dependencies/…`, no `example`). It is load-bearing for RAFT grounding, the fixture unification (P5.3), AND the example-grounded fallback (§2.2). Lift from `// Usage:` headers in `tools/registry.mjs`; **hand-author where no header exists.** **Coverage check is its own guardrail: 100% of injected tags have a valid, lint-passing `example`.** If 100% is unreachable, the RAFT recipe degrades to attribute-name-only grounding — that degradation must be *known*, not silent. | `registry/*.json`, `tools/registry.mjs` | ~1 d (+ hand-backfill) | **YES (gates §4.1)** |
| **P2-B** | **Complete the rest of the injected contract.** Inject `theme-contract.json#variants[tag]` enums; promote the `from`/`src-name`/`rows`/`query`/`csv` binding contract to a `"dataBinding"` doc-string on the `data` dep (DRY, written once). | `work_kits.ex`, `theme-contract.json`, `registry/*.json` | ~0.5 d | high |
| **P3** | **`lintUsage(html, contract)` + measured recall — BLOCKER, the gate is vaporware without it.** `design-lint.js` lints element SOURCE (`lintElementSource`), NOT workbook HTML usage. Build the HTML/usage linter: unknown-tag, unknown-attr, out-of-enum variant, raw-hex-in-style, missing-required-binding, contrast. **Ship with its OWN test suite measuring precision/recall against a hand-labeled flawed-vs-clean set BEFORE any synthetic generation runs.** Expose as `work lint <file.html>`. This IS the §5 deterministic gate AND a model self-check tool. | `src/validate/design-lint.js`, `cli.ex` | **~2 d (parsing + enum-join + measured recall)** | **YES — gates §4.1 / §5 / shape-G labels** |
| **P-traj** | **`slices_in_context` provenance — real host plumbing, gates the flywheel.** Thread the injected contract slice IDs from `work_kits.ex` injection through the agent loop into the trajectory log. **First verify the slice list is recoverable per-turn post-hoc** (the prefix is prompt-cached); if not, emit it at injection time. Without it, `_trajectory.jsonl` lacks the join key for held-out eval + distillation. | `work_kits.ex`, `agent.ex`, trajectory writer | ~1 d (after recoverability spike) | **YES — gates §6** |
| P4 | **`work-ref rel="memory"` + addressable discovery.** Add `rel="memory"`/`rel="state"` so session memory is a first-class declarative edge; make `work components show` + `data-query` registrations retrievable by name from a context-tree node (Retrieval layer). | `work-ref.js` + host route; context-tree epic | 0.5 d + epic | medium |
| P5.2 | **Inject `work-ref rel=` kinds — arguably P1, the spine is unusable without it.** The CEM/registry never tells the model that `rel="kit"` asserts a type, `rel="call"` invokes the Dock, `rel="skill\|agent"` tags provenance, `from=` binds data. Add a `"relKinds"` block (`kit\|skill\|agent\|call\|memory\|from\|to` + one example each) and inject it. | `theme-contract.json`/`work_kits.ex`, `work-ref.js` | 2 h | high |
| P5.1 | **`verbs.json` self-describing CLI** — `work --json` (verb → args → one-line + example) so the model learns NEW verbs zero-shot from a slice. | `cli.ex` | ~3 h | medium |
| P5.4 | **Spine parity everywhere** — `work-src`/`work-ref` missing from `registry/*.json` + `html-custom-data.json`; fix the `tools/registry.mjs` glob to include `src/elements/work/` AND `src/elements/flow/` (so `work-flow` is captured from its real location). | `tools/registry.mjs` | ~1 h | medium (folds into P0c/P1) |
| P5.3 | **Unify example == eval golden == registry example** — the P2-A `example` becomes the `components.ex` fixture AND the rejection-sampler reference (one snippet, three consumers). | folds into P2-A | — | — |

**Throughline:** P0 + P0b + P0c + P1 + P2-A + P2-B + P5.2 together ARE the don't-memorize architecture. **Land P0/P0b/P0c FIRST** — until then the model can't see the library, the build gate is a no-op, and the guardrail reds. **P2-A + P3 + P-traj are the three unbuilt artifacts the corpus quality actually rides on** — the deterministic auto-label, the example grounding, and the flywheel join key. None of them exist today; treat them as the real critical path.

---

## 9. EVAL & SUCCESS BARS

Run every checkpoint against these. Metrics 1–3 are **BLOCKED-ON-P3** (their measurement tool, `lintUsage`, is unbuilt) — do NOT report a checkpoint against them until P3 lands.

| Metric | How measured | Bar | Status |
|---|---|---|---|
| **Usage-lint pass-rate** | `lintUsage` on emitted markup: 0 errors | **≥ 95%** first-try | **BLOCKED-ON-P3** |
| **CEM-tag validity** | every tag ∈ reconciled index | **≥ 99%** | BLOCKED-ON-P0c |
| **Variant-enum conformance** | every variant ∈ `theme-contract.json#variants[tag]` (post enum-join preflight) | **≥ 97%** | BLOCKED-ON-P3 |
| **`work build`/render pass** | tangle + headless mount, no console errors | **≥ 90%** | needs P0b |
| **Novel-schema generalization (Tier-1, shape K)** | compose ≥ 40 unseen-schema tags given only their slice (§2.2) | **≥ 80% lint+build pass — THE KEYSTONE** | the COMPOSE proof |
| **Same-family held-out (Tier-2)** | compose withheld shipped tags given only their slice | **≥ 80%** | sanity tripwire only |
| **Tokens-per-task** | mean output tokens vs SFT-only checkpoint | **−27% to −50%** at **≤ 4%** correctness loss | — |
| **Fix-lane recovery** | given a real lint/build error, reaches a passing fix | **≥ 70%** within 2 turns | — |
| **Assist/honesty** | gemini judge on shapes H/I | **≥ 4/5** mean, **0** hallucinated facts on probes | — |
| ~~Render fidelity (vision judge)~~ | ~~vs canonical `example`~~ | **DEFERRED — vision out of scope; covered by `work build`+render-no-console-error** | dropped |

The **Tier-1 novel-schema bar is the keystone and the only metric that proves the commercial thesis.** Tier-2 passing while Tier-1 fails = the model is memorizing the shipped catalog; the corpus is over-weighted on emit / under-weighted on contract-grounding, and §2.3's rotation mitigation isn't biting. **A green Tier-2 is not a ship signal.**

---

## 10. SEQUENCING (the catalog is etched, not done)

1. **Land P0 + P0b + P0c** — prefix filter, the `work-component`↔`work-src` audit/decision, AND the catalog reconciliation. ~1.5 d. **Nothing else starts first** (model sees only the spine; build gate is a no-op; guardrail reds).
2. **Land P5.4 + P1 spine entries** — `work-src`/`work-ref`/`work-flow` first-class in `registry/*.json` from their real locations.
3. **Land P2-A (`example` backfill to 100%) + P2-B + P5.2** — enums + per-element `example` + binding + rel-kinds. P2-A coverage check must be green.
4. **Land P3 (`lintUsage`) and measure its precision/recall** against a hand-labeled set. **No synthetic generation until this passes.**
5. **Land P-traj (`slices_in_context`)** — verify recoverability, then emit. The flywheel cannot turn without it.
6. **Build the §4.1 synthetic floor** (gated by P3 + the enum-join preflight) — includes Tier-2 held-out; **hand-author the Tier-1 novel-schema eval set (shape K) in parallel.**
7. **Run the §4.2 Claude-CLI teacher** on the full agent surface (teacher carries 100% of fix-lane); MiniMax-M3 for bulk (§4.3).
8. **Wire the harvester** (P-traj capture + the 3-gate filter, with the **fix-lane decoupled from the outcome gate**, §6). Shadow runs seed it but are labeled synthetic.
9. **Phase 1 QLoRA-SFT** → checkpoint → §9 evals (**Tier-1 is the gate**).
10. **Phase 2 ORPO/SimPO** with the **two separate preference sets** (correctness length-matched; length on correct-only).
11. **Serve Q5_K_M**, smoke-test the GGUF on the exact `llama-server --jinja` build; **measure contract-prefill cost** to validate the in-context economics (§7-serve).
12. **Expansion round** — backfill any shape under bar (likely H/I/Tier-1), then re-train.
13. **Turn the flywheel** — production-shadow → harvest *recovered failures* → re-distill on the catalog's next rev (only the in-context slice changes).

---

## 11. OPEN QUESTIONS / RISKS

1. **`example` ground-truth coverage.** Now a **P0 hard deliverable (§8 P2-A)** with a 100%-coverage guardrail, no longer an open question. Residual risk: some elements genuinely lack a clean minimal snippet → hand-author. The fallback degradation is now *measured*, not silent.
2. **Distractor-slice realism.** RAFT needs distractors close enough to tempt. **Adopted:** sample distractors from the *same domain prefix* (sibling elements) so the model must read, not pattern-match the prefix.
3. **Tier-1 novel-schema authoring quality.** The keystone gate is only as honest as the ≥40 hand-authored schemas. Risk: they accidentally resemble the trained grammar (defeating the OOD test). Mitigation: distinct prefixes, novel attribute *value-types*, at least some with a non-`--work-*` token namespace supplied in-slice; review the set adversarially before it gates a ship.
4. **Length penalty × the fix lane.** Now structurally addressed by the **two-preference-set split** (§7) + exempting verified tool-call turns. Residual: tuning the tolerance band.
5. **Catalog churn velocity.** If the catalog moves faster than the teacher can re-cover new *behaviors*, in-context grounding still degrades on genuinely new *shapes*. Mitigation: the synthetic floor regenerates from the registry on every catalog rev (cheap, no teacher); teacher re-runs only for new behaviors.
6. **Naming-generation drift in training data.** The codebase carries two name generations (file `wb-table.js` / class `WbTable` / tag `grid-table`). The corpus must train on the **tag**, not the filename/class. Mitigation: a corpus-hygiene linter rejecting any example referencing a tag absent from the reconciled index (same gate as §5 #1, applied to training data).
7. **`_trajectory.jsonl` privacy surface.** Verbatim turns can hold user data. Mitigation: tenant opt-in + ref-only `var` store + explicit secret-scrub; local-only, never committed.
8. **On-policy distillation teacher cost.** Phase-2.5 gated strictly on a measured forgetting signal (general-replay drop > 5%) or a pref-opt plateau — never speculative.
9. **Serve-time contract-prefill cost (NEW).** The in-context economics assume cheap prefix reuse; on a single-slot CPU box, cross-tenant switches re-prefill. Mitigation: measure prefill cost (§7-serve, step 11); keep the slice small (P1/P2 already drive this) or pin tenants to slots. The compose thesis does not depend on the cache win — it stands on DRY + catalog-churn survival.
10. **Literature transfer is the open empirical question, NOT "solved" (corrected).** RAFT/RAT/Gorilla-RAT are the *right shape*; Gorilla adapts evolving args of known-shape APIs and RAFT reports non-trivial failure on distractor-heavy prompts. Transfer to *structurally-novel* elements is unproven by the literature — **our Tier-1 novel-schema eval is what answers it.** Do not present the papers as having solved our case.

---

## Respect-check on prior decisions
- **Granite-4.1 = pure dense transformer:** folded; Mamba-pinning dropped. ✓
- **Q5_K_M serve on llama.cpp CPU:** respected; the "220×" cache claim removed and replaced with measured single-slot economics (§7-serve). ✓
- **RL = NO:** respected — ORPO/SimPO/on-policy distillation are all non-RL. ✓
- **Vision deferred:** now respected — the render-fidelity vision-judge is **dropped** from both the §5 gate and the §9 bars; render correctness rides on deterministic build + render-no-console-error. ✓
```

**Punch-list disposition** (all 16 items + respect-check): **1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12** (BLOCKERs/MAJORs) — all **fixed** in the body (two-tier held-out + Tier-1 primary; P0c reconciliation + no literal guardrail; P2-A example backfill as hard P0; P3 `lintUsage` BLOCKER with measured recall; §5 enum-join preflight; §2.3 rotation + reframed thesis; §6 fix-lane decoupled from outcome gate + teacher carries it; P-traj host-plumbing task; "220×" dropped for measured single-slot economics; per-shape floor table + expansion round + LIMA misapplication called out; §7 two-preference-set split; P0b re-scoped to a full audit). **10** (scale) — fixed via the per-shape floor table, H/I raised 5→8%, and an explicit expansion round (step 12). **13, 14, 15** (MINORs) — addressed (literature softened to "right shape, open empirical question"; §9 metrics 1–3 flagged BLOCKED-ON-P3; replay budget tied to measured IF-drop via Phase-J, not fixed 2%). **Respect-check vision violation** — fixed (vision judge dropped). **Nothing rejected** — every item was either a real substrate error or a cheap correctness win; none warranted a defended "no."
