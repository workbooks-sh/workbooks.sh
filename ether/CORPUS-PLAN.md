# Ether Training Corpus & Agentic-Alignment Plan

Status: inked. Supersedes the corpus sketch in `corpus-plan.workflow.js`. Builds on
`ETHER-PLAN.md` (model, host, Phase 0→1→2 pipeline), `TRAINING-STRATEGY.md`,
`INFERENCE-VIA-TRAINING.md`, `MODEL-SELECTION.md`. Reads the workponents etch-out as
ground truth: the **3-element spine** (`work-src`/`work-ref`/`work-flow`), **52 tags /
20 domains** (`workponents/registry/index.json#totals`), the machine-readable contract
(`custom-elements.json`, `registry/*.json`, `theme-contract.json`), the lint seam
(`src/validate/design-lint.js`), the theming skill (`skills/theming.md`).

One correction folded in from the Granite front: **Granite-4.1 dense (3B/8B/30B) is a
pure transformer, NOT Mamba-hybrid** — the "Mamba × llama.cpp pinning" risk in
`MODEL-SELECTION.md` applies to the 4.0-H line only and is **dropped** from this plan.

---

## 1. THESIS

We are training Granite-4.1-3B to BE a **catalog-grounded, contract-reading,
full-service workbook agent** — not a component emitter. Its durable competence is a
*procedure*: discover what exists → read the contract slice it was handed → compose
spine + visual elements against ONLY that slice → bundle/build → read the error →
fix → ship → tell the user what happened, honestly. The specific 52 tags, ~80
`--work-*` tokens, and per-element variant enums are **NOT memorized into the
weights**. They are a moving, machine-maintained source of truth supplied at
inference as a stable, prompt-cached contract prefix.

**Verdict: COMPOSE, not memorize.** Fine-tuning installs format/skill reliably and
new facts unreliably (LIMA superficial-alignment; FT-teaches-format-not-facts). A
52-element catalog with per-element attributes/events/tokens is exactly a pile of
low-frequency facts — the first thing catastrophic forgetting eats, and a permanent
re-tune treadmill since the catalog *just moved once already* (`work-*` pile → spine
+ prefixed toolkits). The catalog is already machine-readable; baking it into weights
duplicates a source of truth the substrate maintains for free (DRY at the model
level). The model that survives catalog churn, exploits the 220× prompt-cache TTFT
win (the contract IS the cached prefix), and powers the per-tenant fine-tune factory
(a tenant's catalog differs and must work with zero re-tune) is the one that learns
**read-then-use**, not recall.

---

## 2. WHAT LIVES IN WEIGHTS VS IN-CONTEXT — and the new-verb mechanism (the centerpiece)

### 2.1 The split

**In WEIGHTS (stable format/skill — the right fine-tune target):**
- **Spine grammar** — `<work-src lang=…>` (inline source IS the body), `<work-ref rel=…>`
  (every edge: dependency, binding, AND type), `<work-flow>` (the DAG; pure
  presentation, host fires it). Nesting contracts, "what something IS is an edge not
  an element," composition-as-source. Syntax — stable, durably installable.
- **Theming discipline** — style ONLY from `--work-*` tokens (never raw hex/rgb/hsl),
  variants ONLY from declared enums, `em`/`%`/`clamp()`/`color-mix()` are the legal
  exemptions, lint-before-done. A procedure (`skills/theming.md`), not a palette.
- **The agentic loop shape** — orient → discover → read-contract → compose → bundle →
  `work build`/lint → read-error → fix → ship → assist. A behavior.
- **The read-then-use reflex** — "when you need an element/verb you don't recognize,
  go read its registry/contract slice FIRST." The keystone meta-skill.
- **Edge-as-type reflex** — express "this is a skill/agent/toolkit" as
  `<work-ref rel="skill|agent|kit">`, never invent a `<work-skill>` tag.

**In CONTEXT (volatile facts — supplied at inference, prompt-cached):**
- The 52 tags + per-tag attributes/events (`registry/index.json`, `registry/<tag>.json`).
- The ~80 `--work-*` tokens + roles + types (`theme-contract.json#tokens`).
- The per-element variant enums + defaults (`theme-contract.json#variants`).
- The `rel=` kinds, the `lang` lane routing, the `from=`/binding contract.
- A tenant's bespoke catalog (the product story).

### 2.2 The mechanism: contract-in-prompt SFT (RAFT/RAT-shaped)

This is the load-bearing technique and the literature is one-directional:

- **RAFT (Retrieval-Augmented Fine-Tuning).** Train on `(task, [relevant slice +
  distractor slices], answer that cites the slice verbatim)`. Every composition
  example's prompt includes the `registry/<tag>.json` slice(s) the answer uses, PLUS
  2–4 distractor element slices. The target composes against ONLY the relevant slice
  and references its declared attributes/tokens/variants verbatim. The model learns
  the *operation* "ground generation in the provided contract," which transfers to
  slices it never saw — including a tenant's catalog.
- **Gorilla RAT (the evolving-API precedent).** Gorilla fine-tunes WITH the retrieved
  API doc in-prompt and "adapts to test-time changes of APIs (version/argument
  evolution)." That is *exactly* our moving-catalog problem, already solved: train
  doc-in-prompt, swap the doc at inference, the model tracks the change with no
  re-tune. Our `work-ref rel=toolkit|skill|agent` edges are API references; the
  registry is the doc.
- **Example-grounded fallback.** When a contract slice is thin, include
  ICL-demonstration examples ("here are two uses of an unfamiliar `prefix-*` element,
  produce a third") so zero-shot use is hardened even without a rich slice.

**The held-out-element gate (the proof COMPOSE works).** Deliberately withhold ~20%
of the 52 elements (and a few synthetic future-looking `prefix-*` tags) from *training
answers*. Evaluate the fine-tune on composing the held-out elements **given only their
contract slice**. If it composes them correctly, read-then-use generalized. This is
the single most important eval beyond the `work build` gate — it is the literal test
of "can it learn a verb it never saw."

**Vary the contract presentation** across examples — full slice / minimal slice /
slice + 2 distractors / slice + sibling-prefix slices — so the skill is not welded to
one prompt shape. Always include the `theme-contract.json` token + variant-enum slice
in-prompt and train the answer to draw only from it; design-lint then becomes a hard
verification of "obeyed the contract," not "remembered the palette."

---

## 3. CORPUS COMPOSITION — task shapes with target %

Target **~3,500 execution-verified, deduped, diverse examples** for the cold-start SFT
set (LIMA-scale logic: a narrow domain with a hard executable gate is quality-bound,
not count-bound; do NOT chase 50k mediocre pairs). Mix mirrors the **real agentic loop
distribution**, not the emit-a-component slice — the agent's job is full-service.

| # | Task shape | % | Source | Gate |
|---|-----------|----|--------|------|
| A | **Catalog-grounded component composition** (emit a visual element, contract-in-prompt, RAFT-shaped, distractors) | 22% | registry-synthetic | design-lint + CEM-tag + enum + render |
| B | **Spine usage** (`work-src` lang routing; `work-ref` rel=kit/skill/agent/call/from/to; `work-flow` DAG with in/out/deps) | 14% | registry-synthetic + teacher | structure parse + render |
| C | **Discovery-then-compose** (given a NEW/unseen tag's slice in-context → correct emit; the read-then-use behavior) | 12% | registry-synthetic (held-out split) | enum + tag-exists-in-given-slice |
| D | **CLI / work-verb tool-use** (`work kit show/search`, `unbundle→edit→bundle`, `lint`, `structure`, `build`, single + chained) | 13% | grammar-synthetic from `cli.ex` + teacher | verb exit-code |
| E | **Bundling** (`work bundle <dir> <out.html>`, unbundle round-trip, when-to-bundle-vs-leave-folder) | 7% | teacher + grammar-synthetic | `work verify`/build pass |
| F | **Bash-equivalent compute** (`shell`: ls/cat/jq/grep/pipes to orient + slice data, NOT native exec) | 8% | teacher-distilled | exit-code + output check |
| G | **The fix lane** (compose → lint/build → read REAL error → re-compose; multi-turn) | 12% | **teacher + logs-only** | error→pass transition |
| H | **Research-to-source** (`web_search`→`fetch`→compose with real numbers; the "finding out information" half) | 5% | teacher-distilled | judge (used real data, no fabrication) |
| I | **Assisting / communication** (narrate intent, confirm in prose, honesty/false-premise, `file_issue` escalation, carry-on) | 5% | teacher + logs-only | judge |
| J | **General-instruction replay** (anti-forgetting) | 2% | held-out general SFT set | — |

Synthesizability classes (drives sourcing, §4):
- **Fully synthetic-from-registry (A, B-spine-grammar, C, D-single-verb):** generated NOW
  from `registry/*.json` + `theme-contract.json` + `cli.ex` grammar + design-lint as the
  label generator. ~60% of the surface, **zero logs needed**.
- **Teacher-distilled (B-flow, D-chains, E, F, H, and the happy-path of G/I):** Claude
  Code CLI driven through real end-to-end tasks on this exact tool surface; MiniMax-M3
  for bulk volume. Manufactures the logs-only signal before our fleet exists.
- **Logs-only (the messy tail of G, the dead-ends, real assist texture, long-horizon
  under compaction):** cannot be faithfully synthesized; harvested over time (§6).
  Bootstrapped by the teacher until organic logs accrue.

---

## 4. DATA SOURCES & THE TEACHER SPLIT

### 4.1 Registry-synthetic (the floor — generate first, no teacher cost)

Recipe — a generator script (`ether/corpus/gen_synthetic.exs`) that, per example:
1. Pick a target tag from `registry/index.json`. Pull its `registry/<tag>.json` slice
   (attributes, events, deps) + its `theme-contract.json#variants[tag]` enum +
   `#tokens` role map. Pick 2–4 random distractor slices.
2. Render the prompt as a realistic task ("add a revenue chart to dashboard.html")
   PLUS the relevant + distractor slices inline (RAFT shape).
3. Generate the target answer programmatically from the slice (valid attribute set,
   in-enum variant, token-only styling) — OR have a cheap model fill it and **gate it
   through design-lint** so only lint-clean answers become labels.
4. Tag with `slices_in_context: [<tag list>]` (needed for the held-out eval + the
   flywheel join key).

For the **held-out split**: exclude ~20% of tags from being *target answers* but still
let them appear as in-context slices, so the eval measures pure read-then-use.
For **CLI grammar (D-single)**: enumerate `cli.ex`'s verb tree, emit
`(task, correct verb+args)` pairs directly — the grammar is fully enumerable.
For **lint pairs (feeds Phase-2 preference)**: generate deliberately-flawed
compositions (raw hex, off-enum variant, invented tag), run `lintUsage`, keep
`(flawed, lint-errors, corrected)` triples.

### 4.2 Claude Code CLI trajectories (the teacher — subscription, trajectory distillation)

Drive Claude Code CLI through REAL end-to-end tasks on the **exact 12-tool agent
surface** (`agent.ex`): compose → `work build`/lint → fix → bundle → ship → assist.
Record trajectories in the SAME `_steps.jsonl` / `_trajectory.jsonl` shape the runtime
emits (so teacher data and organic logs are one pipeline). Claude's runs naturally
contain the error-recovery, discovery-dead-end, and assist behaviors that are
otherwise logs-only — that IS the point of trajectory distillation: manufacture the
logs-only signal from a strong teacher before our fleet has produced any. The teacher's
**terseness is the label** (tight jump-to-region → minimal edit → build, NOT
regenerate-the-whole-file) — this front-loads token-economy at SFT before pref-opt runs.

### 4.3 MiniMax-M3 (bulk pattern volume)

Cheap bulk coverage of the synthesizable classes at scale — all 52 elements × task
types, contract-presentation variations. Every output passes the same hard gate (§5);
non-survivors are discarded or become preference negatives.

### 4.4 Real logs (the flywheel — organic, accrues over time)

Harvested from production agent runs once traffic exists (§6). Highest-weight for the
fix lane (real error text), dead-ends, and assist quality. Until then, §4.2/§4.3 stand
in. **You never wait on logs.**

---

## 5. THE GATE — deterministic machine-lint as rejection-sampler

Every example — synthetic, teacher, or harvested — passes a hard gate before it enters
the corpus. The gate IS the auto-label; no human grader for the structural pass/fail.

**Deterministic (no judge — the bulk of the gate):**
1. **CEM-tag-existence** — every emitted tag exists in `registry/index.json`. Invented
   tags (`<work-table>`, `<work-card>`) rejected. (Failure mode #3.)
2. **theme-contract enum conformance** — every `variant`/`tone`/`size`/… value is in
   `theme-contract.json#variants[tag]`. Catches the *silent* off-enum fallback
   (`tone="primary"`, `variant="bordered"` → quietly-wrong UI). (Failure mode #2.)
3. **design-lint** (`src/validate/design-lint.js` + the new `lintUsage(html)`) —
   `off-token-color` (raw hex/rgb), `off-system-value` (bare px on scale props),
   `unknown-token`, `unknown-attr`, `variant-conformance`, `contrast`. Stable
   `{path,rule,message}` shape feeds the fix-lane as turns.
4. **`work build` / tangle / render** — the workbook parses (Floki `tangle_plan`),
   `work-src` bodies tangle, the page renders in the headless mount without console
   errors. (NB the §8 P0-tangler fix is a prerequisite for `work-src` to be discovered.)
5. **CLI exit-code** — for tool-use examples, the verb returned 0 with the expected
   structural output.

**Judge-needed (gemini LLM-judge, the conversational tail):**
- Assist quality / honesty / false-premise handling (task shape I).
- "Used real fetched data, did not fabricate" (task shape H).
- Render fidelity vs. the canonical `example` (vision judge, as in `components.ex`).

The deterministic gate is the cheapest high-quality corpus signal available **pre-logs**:
generate candidates → `lintUsage` + tag/enum check + build → keep survivors as
positives, keep `(flawed, errors, corrected)` as preference pairs. Zero human labels.

---

## 6. THE LOGS FLYWHEEL

**The substrate already exists — wire a harvester onto it, don't build new capture.**
Every exec agent run (`agent.ex`) already emits, at the chokepoint, no opt-in:
- `_steps.jsonl` — `{step, agent, tool, args, output(200B), exit_code, error, dur_ms, ts}`.
- `events.html` — `<work-event>` log (full args + 300B output + final `<work-result>`).
- `_telemetry.db` — SQLite `step_events`/`task_events` ("a bash call broke" is queryable).
- `Ledger` — tamper-evident, attributable signed provenance per run.

**The loop:**
1. **CAPTURE.** Add ONE opt-in artifact: `_trajectory.jsonl` — the **verbatim
   untruncated** assistant turn + tool result + which contract slices were in context
   (`slices_in_context`). The existing 200/300B truncations are right for telemetry,
   useless for SFT. Gate the full copy to opted-in tenants (it can hold user data).
2. **GATE.** Three gates before a trajectory enters the corpus: (a) **outcome gate** —
   ended in `done` with a verifiable success (`work lint` clean, build passed,
   `publish`/`verify` returned a live URL) — the CLI verbs ARE the auto-labels;
   (b) **judge gate** — gemini scores assist/honesty on conversational turns;
   (c) **privacy gate** — tenant opt-in + secret-scrub (`var` store is already
   ref-only; scrub any inlined values). Local-only, never committed (beads canon).
3. **DISTILL.** Winning trajectories → SFT examples `(task, slices_in_context, full
   tool sequence, final answer)`. **Error-recovery runs are the highest-weight** (the
   fix lane). Failed runs → preference negatives for Phase-2.
4. **FEED.** Next SFT/distillation round mixes synthetic (composition/discovery/CLI) +
   harvested (error-recovery/dead-ends/assist). The catalog stays in-context, so a
   catalog rev never invalidates the model — only the in-context slice changes.

**Bootstrap BEFORE logs exist (cold-start):** the §4.1 synthetic floor (~60% of the
surface) + §4.2 Claude-CLI teacher trajectories (the logs-only behaviors) + seed the
harvester by running the bootstrapped model on the existing eval packs
(`components`, `agent_capabilities`) in **production-shadow mode** — those runs are the
first real logs, auto-gated by their own deterministic checks. The flywheel turns from
day one because the gate is the eval harness already in the repo.

---

## 7. TRAINING PIPELINE (fold into Phase 0 → 1 → 2)

**Base:** `ibm-granite/granite-4.1-3b` (Apache-2.0, pure dense transformer, 128K ctx).
**Primary trainer:** Unsloth (first-class Granite-4.1, ships fixed chat templates +
GGUF; IBM's own cookbook uses it). LLaMA-Factory `granite4` template = backup; TRL =
the preference substrate. Axolotl unnecessary for this narrow job.

### Phase 0 — corpus build & gate (§3–§6)
Generate synthetic floor → teacher-distill the logs-only classes → gate everything →
~3,500 verified, deduped, diverse examples + a held-out-element split + a
general-instruction replay set (2%). **Hard hygiene gate: web-component-only — org-mode
denylist is non-negotiable** (the model must not learn deprecated idioms; org is
deprecating).

### Phase 1 — QLoRA-SFT
IBM Granite Snack Cookbook recipe (`FineTuning_with_Unsloth.ipynb`), base swapped to
`granite-4.1-3b`. Don't re-derive these:

| Knob | Value | Delta vs cookbook |
|---|---|---|
| `target_modules` | all 7 (q,k,v,o,gate,up,down) | — |
| `r` / `lora_alpha` | 16 / 16 (scale 1.0) | — |
| `lora_dropout` / `bias` | 0 / none | — |
| `load_in_4bit` | **True** | cookbook is 16-bit; 4.1 dense is QLoRA-safe |
| `max_seq_length` | **8k–16k** | cookbook 2048; our trajectories + slices are long |
| `learning_rate` | 2e-4 | — |
| `num_train_epochs` | 2–3 | watch eval loss, **stop on plateau** (avoid catalog memorization) |
| batch / grad-accum | 2 / 4 (eff. 8) | — |
| `optim` / `wd` / sched | adamw_8bit / 0.01 / linear | — |

Chat template: Granite's own — `<|start_of_role|>…<|end_of_role|>` + `<|end_of_text|>`;
tool calls `<tool_call>{json}</tool_call>`, tool results `<tool_response>`. **Pass tools
via `apply_chat_template(..., tools=[…])` — the template auto-renders the tools system
prompt; do NOT hand-roll it.** `llm.ex` needs a dedicated **Granite recovery branch**
(NOT Qwen's XML dialect).

### Phase 2 — length-penalized preference-opt (RL = NO)
**ORPO** (ref-free, single-stage, length-normalized) as default; **SimPO** if dialing
the length penalty harder (reward = β/|y|·log p — directly penalizes verbosity, removes
DPO's length-exploitation). Avoid plain DPO (needs a frozen ref, length-drifts).
- **Preference pairs from the `work build` gate:** chosen = shorter *passing* output,
  rejected = longer / failing output → length-cut and correctness train as ONE signal.
- **Lazy length penalty:** penalize length **only on CORRECT trajectories, only beyond
  a tolerance band, only after training stabilizes** — so the penalty never truncates
  mid-reasoning. Documented: 27–77% token cut for ≤1–4% accuracy loss.

### Phase 2.5 — on-policy distillation (the forgetting cure, reserved lever)
NOT RL. If pref-opt plateaus OR forgetting appears: distill the served model on its own
recent on-distribution failures, graded by the teacher (Claude-CLI / MiniMax). ~9–30×
cheaper than RL; demonstrably restores IF-eval 85%→45%→83% while keeping new knowledge.
Doubles as the catalog-rev refresh.

### Serve — Q5_K_M on llama.cpp (CPU, bare-metal)
Merge adapter (`save_method="merged_16bit"`) → `convert_hf_to_gguf.py` →
`llama-quantize … Q5_K_M` (3B ≈ 2.44 GB, fits the $11/mo box).
Serving gotchas: **`--jinja` is mandatory** (or tool framing breaks silently);
**train↔serve chat template + EOS must be byte-identical** (mismatch craters quality
with no error); serve greedy (`temp 0, top_p 1, top_k 0`) for deterministic structured
output; **no Mamba-pinning ritual** (dense) — replace it with a single smoke-test of the
exact GGUF on the exact `llama-server` build before committing the box.

---

## 8. SYSTEM FIXES (shrink the corpus + raise reliability + align around memory)

Ranked by leverage. **P0 is a hard prerequisite for ANY corpus work.** P1–P2 are the
*don't-memorize* architecture (deterministic discovery + complete contract slice). P3
manufactures the pre-logs reward signal. P4 makes logs cumulative.

| # | Fix | File | Effort | Prereq? |
|---|-----|------|--------|---------|
| **P0** | **Drop the `work-` prefix filter** — `work_kits.ex:342` does `String.starts_with?(tag, "work-")`, which injects only the 5 spine tags and **hides 49/54 elements from the model**. Gate on `d["customElement"] && d["tagName"]`, or read the allow-list from `registry/index.json`. + guardrail test: catalog count == `registry/index.json#totals.components` (52). | `runtime/host/work_kits.ex` | 30 min | **YES — blocks everything** |
| **P0b** | **Align tangler ↔ spine.** `workbook.ex:209` `component?/1` matches `n.tag == "work-component"`, but the spine compute element is `<work-src>`. A workbook authored with `<work-src lang=…>` is **NOT discovered/compiled** — the build plan finds nothing, so the §5 build gate silently passes empty. Fix: match `work-src` (and keep `work-component` for back-compat). | `runtime/host/workbook.ex` | 1 h | **YES — the build gate is a no-op without it** |
| **P1** | **One canonical index + discovery verb.** Make `registry/index.json` THE index; inject from it (not raw CEM). Add the **missing spine entries** (`work-src`, `work-ref` have no `registry/<tag>.json`) + a `kind` field (`spine\|visual\|lib`). Add `work components [show <tag>]` returning the index slice + the element's contract slice — the deterministic discovery entrypoint a logged trajectory calls. | `work_kits.ex`, `registry/index.json`, `tools/registry.mjs`, `cli.ex` | ~1 d | prereq for shape C |
| **P2** | **Complete the injected contract.** Today the catalog is tag+attr-NAMES only. (a) inject `theme-contract.json#variants[tag]` enums; (b) add a machine-readable `"example"` (minimal valid snippet) per `registry/<tag>.json`, lifted from the `// Usage:` headers, generated in `tools/registry.mjs`; (c) promote the `from`/`src-name`/`rows`/`query`/`csv` binding contract to a `"dataBinding"` doc-string on the `data` dep (written once, DRY). Without enums+example, the corpus must memorize them by rote — bloating data + weights. | `work_kits.ex`, `theme-contract.json`, `registry/*.json`, `tools/registry.mjs` | ~1 d | high — shrinks corpus |
| **P3** | **`lintUsage(html, contract)` + feed the sampler.** design-lint only lints element SOURCE today; an agent emitting `<grid-table variant="bordered">` or raw `#fff` in inline `style=` gets ZERO feedback. Add HTML/usage lint: unknown-tag, unknown-attr, out-of-enum variant, raw-hex-in-style, missing-required-binding. Same `{path,rule,message}` shape. Expose as `work lint <file.html>`. This IS the §5 deterministic gate AND a self-check tool the model calls. | `src/validate/design-lint.js`, `cli.ex` | ~1.5 d | high — pre-logs reward |
| **P4** | **`work-ref rel="memory"` + addressable discovery.** Add `rel="memory"`/`rel="state"` so session memory read/write is a first-class declarative edge (consistent with `rel=call\|kit\|skill`) — the agent *composes* memory access the same way it composes a data binding. Make `work components show` output + `data-query` registrations retrievable by name from a context-tree node (tie to the Retrieval layer) so "what exists" is a read, not a re-reconstruction every turn. | `src/elements/work/work-ref.js` + host route; context-tree epic | 0.5 d + epic | medium (cumulative assist) |
| **P5.2** | **Inject `work-ref rel=` kinds into the contract.** The CEM/registry never tells the model that `rel="kit"` asserts a type, `rel="call"` invokes the Dock, `rel="skill\|agent"` tags provenance, `from=` binds data. This is the spine's whole novel concept, documented ONLY in the `work-ref.js` header. Add a `"relKinds"` block (`kit\|skill\|agent\|call\|memory\|from\|to` + one example each) and inject it. **Arguably P1 — the spine is unusable without it.** | `theme-contract.json`/`work_kits.ex`, `work-ref.js` | 2 h | high |
| P5.1 | **`verbs.json` self-describing CLI** — emit `work --json` (verb → args → one-line + example) so the model learns NEW verbs zero-shot from a slice (the §2 mechanism applied to the CLI). | `cli.ex` | ~3 h | medium |
| P5.4 | **Spine parity everywhere** — `work-src`/`work-ref` missing from `registry/*.json` + `html-custom-data.json`; fix the `tools/registry.mjs` glob to include `src/elements/work/`. | `tools/registry.mjs` | ~1 h | medium |
| P5.3 | **Unify example == eval golden == registry example** — the P2 `example` field becomes the `components.ex` fixture AND the rejection-sampler reference (one snippet, three consumers; stops drift between teach/test/ship). | folds into P2 | — | — |

**Throughline:** P0 + P0b + P1 + P2 + P5.2 together ARE the don't-memorize architecture
— a deterministic discovery entrypoint returning a *complete* contract slice (index +
enums + example + binding + rel-kinds) means the moving catalog stays in-context and the
model trains on catalog-grounded composition behavior over a small contract, not on
memorizing 52 elements. **Fix P0 + P0b FIRST — until then the model literally cannot see
the library and the build gate is a no-op.**

---

## 9. EVAL & SUCCESS BARS

Run every checkpoint against these. The first four are deterministic; the last two use
the gemini/vision judge.

| Metric | How measured | Bar |
|---|---|---|
| **Usage-lint pass-rate** | `lintUsage` on emitted markup: 0 errors | **≥ 95%** of compositions lint-clean first-try |
| **CEM-tag validity** | every tag ∈ `registry/index.json` | **≥ 99%** (zero invented tags is the goal) |
| **Variant-enum conformance** | every variant value ∈ `theme-contract.json#variants[tag]` | **≥ 97%** (the silent failure mode) |
| **`work build`/render pass** | tangle + headless mount, no console errors | **≥ 90%** of full-loop tasks build clean |
| **Held-out-element generalization** | compose withheld tags given only their slice (§2.2) | **≥ 80% lint+build pass** — the COMPOSE proof |
| **Tokens-per-task** | mean output tokens, fixed eval set, vs the SFT-only checkpoint | **−27% to −50%** after Phase-2 at **≤ 4%** correctness loss |
| **Fix-lane recovery** | given a real lint/build error, reaches a passing fix | **≥ 70%** within 2 turns |
| **Render fidelity** | vision judge vs the canonical `example` | **≥ 4/5** mean |
| **Assist/honesty** | gemini judge on shapes H/I (no fabrication, false-premise caught) | **≥ 4/5** mean, **0** hallucinated facts on probes |

The **held-out-element bar is the keystone** — if it passes, read-then-use generalized
and the catalog can move freely. If it fails, the model is memorizing and the corpus is
over-weighted on emit / under-weighted on contract-grounding.

---

## 10. SEQUENCING (the catalog is etched, not done)

1. **Land P0 + P0b** (the prefix filter + tangler↔spine). ~1.5 h. Until these land the
   model sees 5 elements and the build gate is a no-op. **Nothing else starts first.**
2. **Land P5.4 + P1 spine entries** — `work-src`/`work-ref` first-class in
   `registry/*.json`. The 3 most important tags must be machine-readable everywhere.
3. **Land P2 + P5.2** — inject enums + per-element `example` + binding contract +
   rel-kinds. This is what lets the corpus be small.
4. **Land P3** — `lintUsage` + `work lint <file.html>`. This is the §5 gate AND a model
   self-check tool; the synthetic generator depends on it for labels.
5. **Build the §4.1 synthetic floor** (registry-driven, gated by P3) — ~60% of the
   surface, zero teacher cost. Includes the held-out split.
6. **Run the §4.2 Claude-CLI teacher** on the full agent surface; record trajectories in
   `_steps.jsonl`/`_trajectory.jsonl` shape. MiniMax-M3 for bulk volume (§4.3).
7. **Wire the harvester** (P1-capture `_trajectory.jsonl` + the 3-gate filter) so the
   flywheel can turn — even before traffic, the eval-pack shadow runs seed it.
8. **Phase 1 QLoRA-SFT** on the gated corpus → checkpoint → run §9 evals (esp. held-out).
9. **Phase 2 ORPO/SimPO** with lazy length penalty off the build-gate preference pairs.
10. **Serve Q5_K_M**, smoke-test the GGUF on the exact `llama-server --jinja` build.
11. **Turn the flywheel** — production-shadow → harvest → re-distill on the catalog's
    next rev (no re-tune of the *vocabulary*, only the in-context slice changes).

---

## 11. OPEN QUESTIONS / RISKS

1. **`example` ground-truth coverage.** P2-B lifts `example` from `// Usage:` headers,
   but not every element has one. Risk: thin/missing examples weaken the
   example-grounded fallback (§2.2). Mitigation: backfill missing examples by hand for
   the 52 tags as a one-time cost; they're load-bearing (golden == fixture == sampler ref).
2. **Distractor-slice realism.** RAFT needs distractors close enough to be tempting.
   Random distractors may be too easy → the model learns a weak grounding. Mitigation:
   sample distractors from the *same domain prefix* (sibling elements) so the model must
   actually read, not pattern-match the prefix.
3. **Held-out split vs synthetic future tags.** Real held-out elements prove
   generalization to *existing-but-unseen* tags; truly novel structures (a tenant's
   bespoke element with a new attribute shape) may stress read-then-use harder.
   Mitigation: include a few hand-authored synthetic-future `prefix-*` tags with novel
   attribute shapes in the held-out eval.
4. **Length penalty × the fix lane.** Lazy length penalty rewards terseness on *correct*
   trajectories — but the fix lane is intentionally multi-step. Risk: the model learns to
   skip the lint/build self-check to save tokens. Mitigation: exempt verified
   tool-call turns from the length term; only penalize *prose/emit* verbosity.
5. **Catalog churn velocity.** If the catalog moves faster than the teacher can re-cover
   the new surface, even in-context grounding degrades (the model never saw the *shape*
   of the new domain). Mitigation: the synthetic floor regenerates from the registry on
   every catalog rev — cheap, no teacher — so the floor always tracks. Teacher only
   re-runs for genuinely new *behaviors*, not new tags.
6. **Naming-generation drift in training data.** The codebase carries two name
   generations (file `wb-table.js` / class `WbTable` / tag `grid-table` / event
   `work-*`). The corpus must train on the **tag** (`grid-table`), not the filename or
   class. Risk: teacher/synthetic data leaks `wb-*` tags. Mitigation: a corpus-hygiene
   linter that rejects any example referencing a non-`registry/index.json` tag —
   same gate as failure-mode #3, applied to training data itself.
7. **`_trajectory.jsonl` privacy surface.** Full verbatim turns can hold user data.
   Risk: a privacy incident kills the flywheel. Mitigation: tenant opt-in + the existing
   ref-only `var` store + an explicit secret-scrub pass; local-only, never committed
   (beads canon already enforces this for `.beads`).
8. **On-policy distillation teacher cost.** Phase-2.5 is reserved, but Claude-CLI as the
   grader at scale costs subscription budget. Risk: it's invoked too eagerly.
   Mitigation: gate Phase-2.5 strictly on a measured forgetting signal (general-replay
   eval drop > 5%) or a pref-opt plateau — never run it speculatively.
