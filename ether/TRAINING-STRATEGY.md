# Training Strategy: post-training a small model to be a Workponents expert

*How to fine-tune/post-train Granite-4.1-3B (primary) / Qwen3-Coder-30B-A3B (fallback) into an idiomatic, token-efficient Workbooks/Workponents author — and in what ORDER — given synthetic-only data, an executable `work build` verifier, a small team, and CPU-Q4 serving.*

Date: 2026-06-16. Research/preparation only — no code. Builds on `ether/COMPOSER-INSPIRED.md` (Composer transfer + base-model choice) and `ether/GRANITE-EFFICIENCY.md` (CPU serving). Every claim cited to a primary source.

---

## Executive summary (lead bullets)

1. **Recommended method + order: distillation-SFT first, preference-optimization second, RL last (and probably never).** Concretely: **Phase 0** manufacture a corpus by mining components/docs + teacher distillation, **hard-gated through `work build`**; **Phase 1** QLoRA-SFT on the verified corpus (the 80% win); **Phase 2** ORPO or DPO for token-efficiency and idiom, using `work build`-pass + token-count to build preference pairs *for free* from data you already generated; **Phase 3 (optional, deferred)** the cheapest possible GRPO with reward = `build_pass − λ·tokens`, only if Phase 2 plateaus on token-efficiency. Ordering follows Unsloth's own guidance that RL works best *from an already-instruction-finetuned model* ([Unsloth RL guide](https://unsloth.ai/docs/get-started/reinforcement-learning-rl-guide)).

2. **Direct answer on RL-now: NO.** Do not start with RL, and likely never run online RL. For a narrow domain with a teacher and an executable verifier, **distillation-SFT + DPO/ORPO captures most of the gain at a fraction of the cost and infra**; full GRPO buys diminishing returns and needs an online rollout+reward loop we don't have. The one defensible RL use — a tiny GRPO pass with a build-pass+token reward to squeeze token-efficiency — is a *Phase 3 experiment*, not a foundation. Cursor's RL win came from **hundreds of thousands of concurrent sandboxes on thousands of GPUs with a fully async multi-region pipeline** ([Cursor Composer blog](https://cursor.com/blog/composer)) — explicitly not our budget.

3. **The executable `work build` gate is our single biggest asset — use it as a FILTER first, a reward signal a distant second.** Filtering teacher output through compile+render (rejection sampling on execution feedback) is the proven, infra-free way to manufacture a clean SFT corpus ([rStar-Coder](https://arxiv.org/pdf/2505.21297), [RepoST](https://arxiv.org/pdf/2503.07358)). Only train on components that actually compile + render. The same pass/fail becomes the reward *later* if we do Phase 3.

4. **Less is more: a few thousand verified, diverse examples will move a 3B.** LIMA aligned a 65B model with **1,000 curated examples and no RL** ([LIMA, arXiv 2305.11206](https://arxiv.org/abs/2305.11206)); for a *narrow* DSL on a 3B, target ~1–5k verified, deduplicated, coverage-balanced examples over quantity. Diversity/coverage of `wb-*` component patterns matters far more than raw count.

5. **Data hygiene is a hard gate, not a nicety: exclude all org-mode patterns.** We are migrating to a purely web-component system; any org-mode in the corpus teaches a deprecated convention and creates drift. Filter the teacher and the mined corpus against an org-mode denylist *before* the build gate. Mix **5–20% general/base-distribution replay** to limit catastrophic forgetting ([replay guidance](https://zeroentropy.dev/concepts/catastrophic-forgetting/)); QLoRA's frozen base helps but does *not* by itself prevent forgetting ([forgetting survey, arXiv 2501.13669](https://arxiv.org/pdf/2501.13669)).

6. **Composer's lessons translate to SFT, not RL, for us: trajectory distillation on tight edit traces + a strong base + heavy *continued* training.** Composer is ~25% base / 75% Cursor continued-training ([Composer 2 report](https://cursor.com/blog/composer-2-technical-report)); our feasible analog is heavy QLoRA on verified, *token-efficient* trajectories (minimal diffs, jump-to-file, run-tests-then-stop). If we want a cheap on-policy upgrade later, **on-policy distillation** is the standout option — ~9–30× cheaper than RL and a near one-line change over an RL loop ([Thinking Machines](https://thinkingmachines.ai/blog/on-policy-distillation/)).

---

## Our situation (recap, optimized-for)

Lead model **IBM Granite-4.1-3B dense** (Apache-2.0) — a clean, cheap **4-bit QLoRA** target; fallback **Qwen3-Coder-30B-A3B** (MoE, needs bf16-LoRA). Served **Q4_K_M GGUF on CPU** (llama.cpp), single-stream, persistent box. Domain = authoring **Workbooks** (single-file HTML apps) from **Workponents** (themeable Lit `wb-*` web components) + toolkits — **migrating away from org-mode** (hygiene gate). **No usage data** — we manufacture the set by mining our components/docs + distilling a strong teacher. **`work build`/render = executable verifier** (hard gate available on every example). Priorities: (1) correct idiomatic web-component output; (2) token-efficiency; (3) cheap+fast to train (days, rented GPU) and serve (CPU Q4). Small team, **no RL infra**.

---

## 1. Post-training method landscape + decision framework

| Method | What it buys us | Cost / complexity | Data need | Verdict for us |
|---|---|---|---|---|
| **SFT — full fine-tune** | Max capacity to absorb a new DSL | High VRAM, slow, forgets more, fragile GGUF re-quant | Same as LoRA | **No** — overkill for 3B + narrow domain; loses QLoRA's frozen-base forgetting protection |
| **SFT — LoRA (bf16)** | Idiomatic web-component output, cheap adapters | Moderate VRAM; needed for MoE fallback (Qwen3-Coder) | 1–5k verified examples | **Yes (fallback path)** — the MoE route ([Unsloth MoE](https://unsloth.ai/docs/basics/faster-moe)) |
| **SFT — QLoRA (4-bit)** ★ | Same idiom win at lowest cost; cleanest dense re-quant to Q4 GGUF | Lowest VRAM (≈ params in GB); days on rented GPU ([Unsloth](https://unsloth.ai/docs/get-started/fine-tuning-llms-guide)) | 1–5k verified examples | **YES — primary. Phase 1.** IBM ships dense Granite *specifically* as the easy QLoRA target |
| **DPO** | Sharpen idiom/style + token-efficiency from pref pairs | Low-moderate; needs reference model | Chosen/rejected pairs (we generate for free) | **Yes — Phase 2 candidate.** Stable surface in TRL ([TRL docs](https://huggingface.co/docs/trl/index)) |
| **ORPO** | DPO-like win **without** a reference model or separate SFT stage (fuses SFT+pref) | Low; single stage, less memory | Pref pairs | **Yes — Phase 2 candidate**, attractive if we want one combined pass; now *experimental* in TRL ([TRL v1](https://huggingface.co/blog/trl-v1)) |
| **KTO** | Learns from a **binary good/bad** label (no pairs) — maps directly onto `work build` pass/fail | Low | Binary-labeled samples (build-pass = good) | **Yes — strong fit**, because the verifier emits exactly a binary signal ([KTO via TRL](https://huggingface.co/docs/trl/index)) |
| **SimPO** | Reference-free, length-normalized — discourages long outputs (helps token-efficiency) | Low | Pref pairs | **Maybe** — length-normalization aligns with our token goal ([SimPO](https://openreview.net/pdf?id=3Tzcot1LKb)) |
| **RL — PPO/RLHF** | General alignment to a learned reward model | **High** — reward model + value critic + online rollouts | Preference data + RM training | **No** — needs infra/data we lack |
| **RL — GRPO/RFT** | Optimize a *verifiable* reward (build-pass, token-count) directly; no reward model | Moderate-high: online rollout loop, ≥1.5B model, ≥500 rows ideal ([Unsloth RL](https://unsloth.ai/docs/get-started/reinforcement-learning-rl-guide)) | A great reward/verifier > big dataset | **Phase 3 only**, deferred — see §3 |
| **RLAIF** | AI-judge reward when no executable check exists | Moderate; judge cost/noise | Judge prompts | **No** — we have a *real* executor; don't substitute a judge for `work build` |
| **On-policy distillation** | RL-like error-correction at SFT-like density; **fixes forgetting**; ~9–30× cheaper than RL | Low-moderate: student rollouts + teacher log-probs (1 forward pass), "one-line change over an RL loop" | Prompts only; teacher grades tokens | **Best post-SFT *on-policy* upgrade** if Phase 2 underperforms — ([Thinking Machines](https://thinkingmachines.ai/blog/on-policy-distillation/)) |
| **Sequence-level (off-policy) distillation** | Standard teacher→student SFT on full sequences | Low | Teacher completions | **This IS our Phase 1** (verified teacher traces); on-policy beats it on generalization ([Thinking Machines](https://thinkingmachines.ai/blog/on-policy-distillation/)) |
| **Continued pretraining** | Inject large unlabeled domain corpus (raw component source) | Moderate; needs volume | Large raw corpus | **Light/optional** — small over-curated SFT likely beats it for a narrow DSL; reserve if we have lots of raw `wb-*` source |
| **Curriculum learning** | Easy→hard ordering improves convergence on hard code tasks | Low (just data ordering) | Difficulty labels | **Yes — cheap to layer in** (single component → multi-component → full workbook); proven in code RFT ([PyTorch→Triton RFT](https://predibase.com/blog/introducing-reinforcement-fine-tuning-on-predibase)) |
| **QAT (quantization-aware training)** | Recover accuracy lost to 4-bit serving | Higher train cost; QAT recovers ~67–70% of quant loss, +~1% raw ([Unsloth QAT](https://unsloth.ai/docs/blog/quantization-aware-training-qat)) | Same as SFT | **Defer** — only if post-QLoRA Q4_K_M shows real DSL-correctness regression vs the merged model (the open question from GRANITE-EFFICIENCY) |

**Decision framework (the rule we apply):** *Do you have labeled demonstrations of the target behavior?* → SFT. *Do you have a cheap way to rank/binary-label outputs?* → preference optimization (DPO/ORPO/KTO/SimPO). *Do you have an environment + reward + online-rollout infra and SFT has plateaued?* → RL/GRPO. We answer **yes, yes, no** — so SFT → preference-opt is the path, RL is gated behind a plateau we haven't hit. GRPO "doesn't even need much data — all you need is a great reward function/verifier" ([Unsloth RL guide](https://unsloth.ai/docs/get-started/reinforcement-learning-rl-guide)), which is seductive given our verifier — but it trades the data requirement for an *online compute/orchestration* requirement we'd have to build.

---

## 2. Recommended phased plan (with rough $/effort)

**Phase 0 — Manufacture + verify the corpus (the real work; ~1–2 weeks human effort, ~$50–200 teacher API).**
Mine existing `wb-*` components + docs; distill a strong teacher (Claude/GPT/cloud-Qwen) for (a) prompt→component pairs and (b) edit-trajectory traces. Apply the **org-mode denylist**, then the **`work build`/render hard gate** — keep only what compiles + renders (rejection sampling on execution feedback, [rStar-Coder](https://arxiv.org/pdf/2505.21297)). Target ~1–5k verified, deduplicated, coverage-balanced examples. *Output: a clean SFT set + a held-out eval set + a reusable verifier harness.* This is where 70% of the value is created.

**Phase 1 — QLoRA-SFT on Granite-4.1-3B (the 80% capability win; ~1–3 days, ~$20–100 rented single-GPU).**
4-bit QLoRA on the verified corpus + 5–20% general replay; light curriculum (single → multi-component → full workbook). Merge → convert → re-quantize **Q4_K_M** (re-run imatrix on DSL data per GRANITE-EFFICIENCY). Gate on the Workbooks eval (pass-rate **and** tokens-per-task). *Most teams should ship after this.* LIMA-scale data is sufficient here ([LIMA](https://arxiv.org/abs/2305.11206)).

**Phase 2 — Preference optimization for idiom + token-efficiency (~1–2 days, ~$20–80).**
From Phase-0 generation we already have multiple candidates per prompt with build-pass and token-counts attached → build pairs **for free**: chosen = passes-build & fewer-tokens & idiomatic; rejected = fails-build or bloated/deprecated. Run **ORPO** (no reference model, fuses with SFT — simplest) or **DPO** (stable in TRL). Consider **SimPO**'s length normalization to directly penalize verbosity ([SimPO](https://openreview.net/pdf?id=3Tzcot1LKb)), or **KTO** since `work build` already emits a binary good/bad ([KTO/TRL](https://huggingface.co/docs/trl/index)). This is where we chase Composer's token-efficiency win without RL.

**Phase 3 — (OPTIONAL, DEFERRED) cheapest GRPO OR on-policy distillation (~1–2 weeks infra + GPU; only if Phase 2 plateaus).**
Two options, prefer the second:
- *GRPO/RFT*, reward = `build_pass − λ·tokens` (and idiom-lint terms): infra-light by RL standards (no reward model, [Unsloth RL](https://unsloth.ai/docs/get-started/reinforcement-learning-rl-guide)) but still needs an online rollout+verify loop and ≥1.5B model (Granite-3B qualifies).
- ***On-policy distillation*** — usually the better buy: student rollouts graded token-wise by the teacher; **~9–30× cheaper than RL**, "one-line change over an RL implementation," and it *also recovers forgotten general skills* ([Thinking Machines](https://thinkingmachines.ai/blog/on-policy-distillation/)). Recommended over GRPO for our narrow domain.

**Total to a shippable specialist: Phases 0–2, ~2–3 weeks, low-hundreds of dollars.** Phase 3 is a later optimization, not a dependency.

---

## 3. Should we do RL? Direct answer: not now, probably never (one narrow exception)

**No — do not start with RL, and treat online RL as a deferred experiment.** Rationale:

- **SFT+DPO suffices for the core goal (correct idiomatic output).** For a *narrow* DSL with a teacher, verified distillation-SFT is the proven path; preference-opt then sharpens style/efficiency. RL's advantage is "excelling at a specific behavior via an environment + reward rather than labeled data" ([Unsloth RL guide](https://unsloth.ai/docs/get-started/reinforcement-learning-rl-guide)) — but we *have* labeled data (the teacher) and a verifier, so we don't need RL to learn the mapping.
- **RL's documented code wins came bundled with cold-start SFT + curriculum, not RL alone.** The PyTorch→Triton RFT result "combined cold-start supervised fine-tuning with reinforcement learning (GRPO) and curriculum learning" ([Predibase RFT](https://predibase.com/blog/introducing-reinforcement-fine-tuning-on-predibase)) — i.e., SFT does the heavy lifting; GRPO is the finisher. Order matters: RL after SFT.
- **The infra gap is real and we should be honest about it.** Cursor's token-efficiency RL ran on **hundreds of thousands of concurrent sandboxes, thousands of GPUs, async multi-region** ([Cursor Composer](https://cursor.com/blog/composer)). Our cheapest GRPO would be a single-box online loop — feasible but a multi-week build with no online-RL experience on the team.
- **The narrow exception where RL is worth it:** if after Phase 2 our **tokens-per-task** metric stalls above target, a small GRPO/RFT pass with reward = `build_pass − λ·tokens` directly optimizes the one thing SFT/DPO can't fully express (a *continuous* efficiency objective over full generations). GRPO needs only "a great reward function/verifier" and works from ~10–500 rows ([Unsloth RL](https://unsloth.ai/docs/get-started/reinforcement-learning-rl-guide)) — and we have the perfect verifier. **But even here, prefer on-policy distillation**: ~9–30× cheaper than RL, dense per-token feedback instead of sparse episode reward, and a near one-line change over an RL loop ([Thinking Machines](https://thinkingmachines.ai/blog/on-policy-distillation/)). **Cheapest RL we could actually run = a single-box GRPO with the `work build` verifier as reward; it is *not* worth it over distillation-SFT+DPO for v1.**

---

## 4. Data strategy

**Mining + distillation.** Two sources: (a) **mine** existing `wb-*` components + docs into prompt→component and into refactor/edit traces; (b) **distill** a strong teacher (Claude/GPT/cloud-Qwen) — pick the strongest available, since the student inherits the teacher's ceiling; knowledge distillation passes more calibrated signal than raw SFT ([NeMo KD](https://docs.nvidia.com/nemo-framework/user-guide/24.12/modelalignment/knowledge-distillation.html)). **Prompt design:** give the teacher our component inventory + theming conventions + a few canonical exemplars in-context, ask for varied tasks across the `wb-*` surface, and request *tight* edits (minimal diffs, jump-to-file) to seed token-efficiency.

**The `work build` gate — filter first, reward later.** Generate **multiple candidates per prompt**, run each through compile+render, **keep only passers** (rejection sampling on execution feedback — "rejection sampling consistently improves performance… data quality curated by rejection sampling is critical," [rStar-Coder](https://arxiv.org/pdf/2505.21297); [RepoST](https://arxiv.org/pdf/2503.07358)). Pass/fail + token-count are recorded per candidate so the **same generation run yields both the SFT set (Phase 1) and the preference pairs / binary labels (Phase 2)** — and the reward signal (Phase 3) for free.

**Dataset size — less is more.** LIMA: **1,000 curated examples, no RL**, on a 65B ([LIMA](https://arxiv.org/abs/2305.11206)). For a narrow DSL on a 3B, **~1–5k verified, diverse examples** is the target; over-curation beats volume. Diversity/coverage of component patterns (every `wb-*` element, theming variants, composition depths, common toolkits) is the real lever — measure coverage explicitly.

**Catastrophic-forgetting mitigation.** Mix **5–20% general/base-distribution replay** into SFT ([replay guidance](https://zeroentropy.dev/concepts/catastrophic-forgetting/)). QLoRA's frozen base helps but is *not* sufficient alone — LoRA "does not alleviate catastrophic forgetting" by itself ([forgetting survey, arXiv 2501.13669](https://arxiv.org/pdf/2501.13669)). If forgetting bites, **on-policy distillation recovers near-full general performance with a 70-30 domain/chat mix** ([Thinking Machines](https://thinkingmachines.ai/blog/on-policy-distillation/)).

**Org→web-component hygiene (hard gate).** Apply an **org-mode denylist** to *both* mined and teacher-generated data *before* the build gate — any org-mode syntax/pattern teaches a deprecated convention and re-introduces the very drift we're migrating away from. Verify the held-out eval contains **zero** org-mode and only web-component idioms, so the metric can't reward backsliding.

---

## 5. Composer-specific lessons applied to training (building on COMPOSER-INSPIRED.md)

- **Agentic/tool-centric training for token-efficiency → SFT on tight trajectories.** Composer trained in its real harness with efficiency rewards ([Composer 2 report](https://cursor.com/blog/composer-2-technical-report)). Our feasible analog (no 100k-sandbox RL): **trajectory-distillation SFT** on curated efficient traces — minimal edit-region diffs, jump-to-file over full reads, run-`work build`-then-stop, no redundant re-reads — then a **DPO/SimPO/KTO** pass that prefers fewer-token, build-passing completions. This is the headline token-efficiency play *without* their infra.
- **Trajectory distillation on tight edit traces.** Make the teacher emit *edit traces*, not just final files; gate each trace's final state through `work build`; train on the whole trajectory. This teaches the *process* (efficient navigation) that produces the token win, not just the artifact.
- **"Strong base + heavy continued training" → strong *servable* base + heavy QLoRA.** Composer ≈ 25% base / 75% continued ([emelia.io](https://emelia.io/hub/cursor-composer-2-review)). Our analog: a clean dense base (Granite-3B for cheap QLoRA, or the MoE fallback for served capability) + heavy domain QLoRA + preference-opt. The fine-tune, not the base, decides Workbooks quality.
- **Their RL → our on-policy distillation.** The closest feasible substitute for Composer's RL is **on-policy distillation** (student rollouts, teacher token-grading): RL-style error-correction at ~9–30× lower cost, with the bonus that it doubles as forgetting-mitigation and continual-learning ([Thinking Machines](https://thinkingmachines.ai/blog/on-policy-distillation/)). If we ever want the "trained in the loop" effect, this is the rung — not full GRPO.

---

## Data-pipeline sketch

```
mine wb-* components + docs ─┐
                            ├─► PROMPT SET (tasks across the wb-* surface, edit traces)
teacher (Claude/GPT/Qwen) ──┘        │
                                     ▼
                    GENERATE k candidates / prompt
                                     │
                    ORG-MODE DENYLIST  (drop deprecated patterns)
                                     │
                    work build / render  ── fail ──► discard (record fail = "rejected"/"bad")
                                     │ pass
                                     ▼
        ┌──────────── record {prompt, completion, tokens, build=pass} ───────────┐
        ▼                              ▼                                          ▼
  SFT set (Phase 1)          preference pairs / KTO labels (Phase 2)     reward signal (Phase 3)
  + 5–20% general replay     chosen = pass & fewer-tokens & idiomatic    build_pass − λ·tokens
  + curriculum order         rejected = fail | bloated | deprecated
```

One generation+verify run feeds all three phases.

---

## Biggest risks / open questions

- **Teacher ceiling + idiom drift.** The student inherits the teacher's conventions; if the teacher doesn't know our *exact* `wb-*` idioms, distilled data encodes near-misses that pass `work build` but aren't idiomatic. *Mitigation:* rich in-context exemplars; an idiom-lint term in the preference signal, not just build-pass.
- **`work build` passes ≠ correct/idiomatic.** Compile+render is necessary, not sufficient — bloated or non-idiomatic components can still pass. *Mitigation:* layer render-fidelity/lint checks; keep tokens-per-task and an idiom rubric as first-class metrics.
- **Coverage gaps.** A few thousand examples can under-cover rare `wb-*` patterns → the model fabricates. *Mitigation:* explicit coverage matrix over the component inventory; oversample rare patterns.
- **Forgetting despite QLoRA.** Frozen base ≠ no forgetting ([arXiv 2501.13669](https://arxiv.org/pdf/2501.13669)). *Mitigation:* 5–20% replay; on-policy distillation as the recovery tool if needed.
- **Q4 serving regression.** Post-QLoRA Q4_K_M may lose DSL correctness vs the merged model (open question from GRANITE-EFFICIENCY). *Mitigation:* eval the *quantized* model, not just the adapter; QAT only if a real gap appears ([Unsloth QAT](https://unsloth.ai/docs/blog/quantization-aware-training-qat)).
- **MoE fallback complicates the pipeline.** Qwen3-Coder-30B-A3B needs bf16-LoRA (not 4-bit QLoRA) and router-aware handling ([Unsloth MoE](https://unsloth.ai/docs/basics/faster-moe)) — more VRAM, fragile GGUF re-quant. Keep Granite-3B as the primary training target; treat MoE as a serving-capability fallback, not the default train path.
- **If/when to actually pull the RL trigger.** Open: does Phase 2 (DPO/ORPO/SimPO/KTO) get tokens-per-task to target? Only if it plateaus do we spend the multi-week on-policy-distillation/GRPO build — decide on the *measured* metric, not in advance.

---

## Sources

- [LIMA: Less Is More for Alignment · arXiv 2305.11206](https://arxiv.org/abs/2305.11206)
- [On-Policy Distillation · Thinking Machines Lab](https://thinkingmachines.ai/blog/on-policy-distillation/)
- [Reinforcement Learning (RL) Guide · Unsloth Docs](https://unsloth.ai/docs/get-started/reinforcement-learning-rl-guide) · [Fine-tuning LLMs Guide](https://unsloth.ai/docs/get-started/fine-tuning-llms-guide) · [Faster MoE FT](https://unsloth.ai/docs/basics/faster-moe) · [QAT](https://unsloth.ai/docs/blog/quantization-aware-training-qat)
- [TRL — Transformers Reinforcement Learning docs](https://huggingface.co/docs/trl/index) · [TRL v1.0 blog](https://huggingface.co/blog/trl-v1)
- [SimPO: Simple Preference Optimization (reference-free, length-normalized)](https://openreview.net/pdf?id=3Tzcot1LKb)
- [Cursor — Composer: Building a fast frontier model with RL](https://cursor.com/blog/composer) · [A technical report on Composer 2](https://cursor.com/blog/composer-2-technical-report) · [Composer 2 review / compute split · emelia.io](https://emelia.io/hub/cursor-composer-2-review)
- [Predibase — Reinforcement Fine-Tuning (PyTorch→Triton, cold-start SFT + GRPO + curriculum)](https://predibase.com/blog/introducing-reinforcement-fine-tuning-on-predibase)
- [rStar-Coder: Scaling Competitive Code Reasoning with a Verified Dataset · arXiv 2505.21297](https://arxiv.org/pdf/2505.21297) · [RepoST: Sandbox-tested code env construction · arXiv 2503.07358](https://arxiv.org/pdf/2503.07358)
- [NVIDIA NeMo — SFT with Knowledge Distillation](https://docs.nvidia.com/nemo-framework/user-guide/24.12/modelalignment/knowledge-distillation.html)
- [How to Alleviate Catastrophic Forgetting in LLMs Finetuning · arXiv 2501.13669](https://arxiv.org/pdf/2501.13669) · [Catastrophic forgetting / replay · zeroentropy](https://zeroentropy.dev/concepts/catastrophic-forgetting/)
- [DPO Isn't Enough: SimPO, ORPO, KTO and Beyond · J. Fahey](https://medium.com/@fahey_james/dpo-isnt-enough-the-modern-post-training-stack-simpo-orpo-kto-and-beyond-d82e52a1ee6c)
- Builds on: `ether/COMPOSER-INSPIRED.md`, `ether/GRANITE-EFFICIENCY.md`
