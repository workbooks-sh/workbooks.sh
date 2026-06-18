# Ether — The Plan

CPU-served, self-hosted, fine-tunable small models for the Workbooks domain. Sibling to Nexus
(the GPU/runtime plane). North star: a flat-rate "$20/mo unlimited" coding model that runs on
cheap bare metal — and, because the fine-tune pipeline is reusable, a **self-serve feature**
where any tenant fine-tunes *their own* model on *their own* workbooks.

Status: research + validation DONE. Implementation gated on the org→web-component migration
settling (training corpus must be web-component-only). Nothing running / no spend right now.

---

## 1. Architecture (validated)
- **Persistent shared-model box, not per-invocation microVMs.** Persistent kills cold-start,
  is flat/predictable, packs users, and matches Nexus. Per-invocation microVM is the elastic
  tier only (carries a brutal cold-start). [CPU-PERFORMANCE-MODEL.md, GRANITE-PLAN.md]
- **Host on bare metal, not Fly/DO.** RAM is the cost driver (Fly/DO ~$5/GB-mo; Hetzner bare
  metal ~$1/GB). Best value: **Hetzner AX162-R (EPYC-9454P Genoa, 12-ch DDR5, ~€199/mo flat)**
  ≈117 t/s for a 3B; Vultr bare metal for US latency. Fly stays the light control plane only.
- **Decode is memory-bandwidth-bound** (tok/s ≈ bandwidth ÷ model-bytes/token). Bandwidth
  (channels × DDR-gen) >> cores >> flags. Validated: Granite-3B 20→67 t/s and prefill 42→300
  just moving 2-core Milan → 12-core Genoa+AVX-512; bare metal pushes further.
- **Prompt/KV caching = 220× TTFT win** on our repeated DSL preamble — an architecture
  decision (stable context as a cached prefix), free.

## 2. Model decision
- **Lead: IBM Granite-4.1-3B dense (Apache-2.0).** It's the cheap, clean **4-bit QLoRA** target
  and fast to serve (2GB, ~67 t/s, fits an $11/mo box). 4.1's main line is dense *by design*
  (IBM: easier fine-tuning, predictable latency) — exactly why it suits us.
- **Fallback / quality tier: Qwen3-Coder-30B-A3B (Apache-2.0, MoE 3.3B-active).** Decodes near
  3B speed (55 t/s) but carries 30B coding skill; better base output, but MoE → pricier
  bf16-LoRA, bigger box, breaks spec-decode. Use if fine-tuned Granite doesn't clear the bar.
- **Not GLM-4.7-Flash** (token-hungry "thinking" model), **not MiniMax-M3** as a served model
  (264GB — frontier tier, separate big-box story; it's a *teacher*, see below).
- **MoE on Granite?** Only in 4.0 (H-Tiny 7B/1B-active, H-Small) — harder fine-tune target,
  lower ceiling than Qwen. Don't upcycle dense→MoE (needs pretraining-scale compute). For a
  *narrow fine-tuned* domain, dense is the right tool; MoE's extra capacity matters less.
- **Base output quality (measured, same prompt):** Qwen clean & correct; Granite-3B plausible
  but buggy (invalid CSS, requirement-not-wired) — **fine-tuning is expected to close this for
  our narrow idioms.** That bet is what the pipeline tests empirically.

## 3. The training pipeline (the actual product lever)
Order (both research briefs converge): **distill+verify corpus → QLoRA-SFT → length-penalized
preference-opt → serve Q5.** [TRAINING-STRATEGY.md, INFERENCE-VIA-TRAINING.md]

- **Phase 0 — Corpus.** Manufacture instruction→component pairs + agentic traces; **hard-gate
  every example through `work build`/render** (rejection sampling on execution feedback — our #1
  asset). ~1–5k verified, diverse, deduped examples (LIMA: less is more). **Org-mode denylist**
  hygiene gate. 5–20% replay vs forgetting.
  - **Teachers (split by job):**
    - **Claude Code CLI (subscription, free) — PRIMARY, for trajectory distillation.** It
      produces real *agentic traces* (jump-to-file → edit-region → `work build` → fix), which
      teach **token-efficiency + agentic discipline** (Composer's biggest win), not just final
      code. Highest quality, no per-token cost.
    - **MiniMax-M3 via OpenRouter — for bulk volume.** Cheap programmatic generation of many
      "build wb-X" → code pairs to fill pattern coverage. Per-token but cheap.
  - Both outputs pass the same `work build` gate before entering the set.
- **Phase 1 — QLoRA-SFT Granite-3B** on the verified corpus. *The 80% win.* 4-bit QLoRA, <$30,
  days not weeks. Corrects the buggy-but-plausible patterns into our verified idioms.
- **Phase 2 — Preference-optimization with a length penalty (ORPO/SimPO).** The convergence
  point: simultaneously (a) fixes idiom correctness (prefer `wb-build`-passing outputs) AND
  (b) delivers the **#1 inference-speed lever — token-efficiency** (length-penalized training
  cuts 27–50% of tokens at ≤4% accuracy = proportional wall-clock cut, zero new infra).
- **RL: NO** (both briefs). SFT + preference-opt captures the gain without Cursor's RL infra.
  Deferred / maybe-never; if Phase 2 plateaus, use **on-policy distillation** (9–30× cheaper
  than GRPO, also fixes forgetting), not real RL.
- **Quant: serve Q5_K_M, skip QAT.** Q5 (+1.1% ppl, ~7% slower) dodges Q4's degradation
  (+3.3%) for zero training effort. Measure Q4 vs Q5 on the eval, pick.
- **Speed-head spec-decode (EAGLE3/MTP): ONE timeboxed spike, low expectations.** Flags are
  merged in llama-server (`--spec-type draft-eagle3`/`draft-mtp`) but every benchmark is GPU;
  CPU spec-decode hits the same compute wall that sank our separate-drafter test. Not the plan.

## 4. Evaluation (already wired)
Agentic, in-harness, web-component-centric (org deprecating). The integration is DONE:
`llm.ex` `WB_LLM_BASE_URL` + XML tool-call recovery → our agent drives a self-hosted llama-server
model. Score per model by **`work build`/render gates + LLM judge + tokens-per-task**, workbooks
laid side-by-side. Build the case suite + run per model (Granite-fine-tuned vs Qwen) as the
decision gate. [agent_evals.exs, evals/components.ex, Workbooks.Agent.run/3]

## 5. Productization — the pipeline IS a feature
The reason Granite matters beyond "our cheap model": **the whole pipeline generalizes.**
- We prove it on **our** Granite (dogfood): our docs + components → fine-tuned Granite-3B.
- Then expose it as a **self-serve tenant capability**: a tenant points the pipeline at *their*
  workbooks/components/docs, picks a teacher, runs the same `work build`-gated distill→QLoRA, and
  gets *their own* specialized model served on *their own* Ether box. Fits the project's
  per-tenant nexus / BYO-infra canon exactly: "bring your data, fine-tune your model, serve it
  cheap on CPU." This is the durable platform story — not a single model, a fine-tuning factory.

## 6. Economics
- Per-token: self-host loses to commodity API (physics — GPU batching). Don't sell tokens.
- Per-user on a flat-rate owned box: **~$5–10/user/mo on a ~$199/mo bare-metal Genoa** (shared
  model + prompt-cache + bursty users → ~20–40/box) → healthy at $20/mo unlimited. Linear scale.
- Training cost to ship Phases 0–2: **~2–3 weeks, low-hundreds of dollars** (rented GPU for the
  LoRA; teacher mostly free via Claude Code subscription).

## 7. Sequencing / dependencies
1. **WAIT** on the org→web-component migration to settle (corpus must be web-component-only).
2. Then **Phase 0** (the `work build`-gated corpus) — serves whichever model we pick; first thing.
3. Phase 1 SFT → eval gate (fine-tuned Granite-3B vs base Qwen on the agentic eval).
4. Phase 2 preference-opt → re-eval (quality + tokens-per-task).
5. Serve on bare metal (Q5, prompt-cache, pack users).
6. Generalize the pipeline into the self-serve tenant feature.

## 8. Vision (deferred to Phase-3 — research only, no model downgrade)
Goal: the model "proofs its own work" — reads a rendered screenshot of a workbook/UI it
generated and critiques it (layout/contrast/binding). **We will NOT downgrade the text brain
for vision** (user, 2026-06-16). [VISION-PATH-B-RESEARCH.md]
- **LFM2/Liquid is OUT** — LFM Open License caps commercial use at $10M/yr revenue = a permanent
  strategic liability. Apache-2.0 Granite/Qwen only.
- **No `granite-4.1-vision` exists.** IBM ships only `granite-4.0-3b-vision` (brain = Granite-4.0-
  Micro, not 4.1; custom head: SigLIP2 + Window-Q-Former + Deepstack).
- **GGUF is now live:** llama.cpp **PR #23545 "Granite4 Vision" merged 2026-06-05** → 4.0-3b-vision
  is GGUF-runnable today (the old IBM "not possible" doc is stale).
- **No grafting shortcut:** SigLIP encoder reusable, projector NOT (learned against 3.x's exact
  embedding basis/tokenizer) → building our own VLM mandates stage-1 re-alignment.
- **Building our own 4.1-VL = real per-architecture llama.cpp C++** (not encoder-agnostic) — only
  ever build to an arch llama.cpp already supports. Turnkey trainers can't bolt an encoder onto a
  bare text LLM (need Prismatic/TinyLLaVA). Corpus = our existing render→screenshot→gemini-judge.
- **Decision:** (1) text-only now, $0; (2) Phase-3 entry = adopt `granite-4.0-3b-vision` GGUF as a
  **separate critic** (days, ~$0 — 4.0 brain fine for critiquing, never authors, 4.1 stays the
  brain); (3) build a true Granite-4.1-VL (~2-6 wks, ~$1-5k) only if (2) underperforms AND no
  4.1-vision has shipped. Risk: Granite-on-llama.cpp version pinning — smoke-test exact GGUF on
  exact build.

## Open questions
- Does fine-tuned Granite-3B clear the quality bar on our narrow domain, or do we need
  bf16-LoRA Qwen-MoE? (Empirical — the eval decides.)
- Q4 vs Q5 serving quality after fine-tune.
- Claude Code CLI throughput/rate limits as a bulk trajectory teacher vs MiniMax-M3 for volume.
- The EAGLE3-on-CPU spike: net win or wash at draft-n≈2.
