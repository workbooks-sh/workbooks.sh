# Composer-Inspired: a strategy brief for our CPU-served small-model coding system

*What a self-hosted, CPU-served, QLoRA-fine-tuned small coding model should learn from Cursor's Composer models — and whether Granite-4.1-3B dense is the right base.*

Date: 2026-06-16. Every claim cited to a primary source (Cursor blog / technical report, model cards, benchmark writeups).

---

## Executive summary (lead bullets)

1. **Switch the base model.** Move off Granite-4.1-3B *dense* to a **small-active-param MoE** — primary recommendation **Qwen3-Coder-30B-A3B-Instruct** (30.5B total / **3.3B active**, Apache-2.0). On a bandwidth-bound CPU it decodes roughly like a **3B dense** model (only active experts stream per token) while carrying 30B-worth of coding capability resident in RAM — exactly the trade our bare-metal "RAM is cheap" boxes are built for. ([Qwen3-Coder card](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct), [llama.cpp MoE offload guide](https://huggingface.co/blog/Doctor-Shotgun/llamacpp-moe-offload-guide))

2. **The single most important Composer lesson is token efficiency as a first-class RL/training target, not quality alone.** Composer's biggest practical win is doing the *same task in far fewer tokens* via **compaction-in-the-loop RL**: when its 200k-token window fills, it compresses its own working context to ~1k tokens and continues, learned as part of the reward — **~50% fewer compaction errors at ~1/5 the tokens** vs prompt-based summarization. ([essamamdani writeup of Composer 2.5](https://www.essamamdani.com/blog/composer-25-cost-compression), [Composer 2 report](https://cursor.com/blog/composer-2-technical-report))

3. **We can get most of that token-efficiency win through SFT, not full RL.** We lack Cursor's "hundreds of thousands of sandboxed environments" + 5-hour production RL loop ([Composer blog](https://cursor.com/blog/composer)). The feasible analog: **trajectory-distillation SFT** — log/curate efficient agent traces (tight edit-region diffs, jump-to-file instead of full reads, run-tests-then-stop, self-summarize) and QLoRA on them. Optionally a cheap **DPO/GRPO** pass scoring token-count + task-pass. This is the highest-leverage thing we can do.

4. **MoE breaks the drafter-style speculative decoding we might have planned, but Composer's own answer transfers: self-draft layers, not a separate draft model.** Composer 2 trains *additional speculative-decoding layers into the model* (Medusa/EAGLE-style) for **2–3× faster inference** ([philschmid](https://www.philschmid.de/kimi-composer-context)). Classic separate-drafter spec-decode is weak-to-negative on small-active MoE (verifying K tokens routes to many experts → 2–3× data movement, and a 3B-active target leaves no cheap-enough drafter). ([arXiv SP-MoE 2510.10302](https://arxiv.org/html/2510.10302v1), [mlx-lm #1132](https://github.com/ml-explore/mlx-lm/issues/1132))

5. **Our validated prompt-caching = Composer's cache-read; keep leaning on it.** Composer is built "from the ground up for low-latency" agentic loops where the same system prompt + harness recur; KV-cache reuse is the standard mechanism. Our measured **220× TTFT win** is the CPU expression of the same idea — and it matters *more* on CPU because prefill (prompt processing) touches more experts than decode, so first-token latency is the worst part of MoE on CPU. Cache it away. ([Composer blog](https://cursor.com/blog/composer), [MoE offload guide](https://huggingface.co/blog/Doctor-Shotgun/llamacpp-moe-offload-guide))

6. **"Strong open base + heavy continued training" is the validated recipe and our exact mandate.** Composer 2 ≈ **25% compute from the base (Kimi K2.5), 75% from Cursor's own continued pretraining + RL** ([emelia.io review](https://emelia.io/hub/cursor-composer-2-review) citing Cursor's Lee Robinson). Lesson: pick the best open base you can serve, then spend your compute on *coding-specialized continued training* — for us, QLoRA on Workbooks DSL (single-file HTML, `wb-*` Lit components, toolkits, org-mode). The base choice matters less than the fine-tune; but a MoE base makes the fine-tune *cheaper to serve*.

---

## Our context (recap)

Quantized coding model on CPU (llama.cpp, GGUF), cheap dedicated/bare-metal (AMD EPYC, AVX2; big-RAM MoE viable). One model per box, persistent, single-stream per request. Task = code/DSL authoring (Workbooks single-file HTML, Lit `wb-*` components, toolkits, org-mode). QLoRA fine-tune planned. Current default Granite-4.1-3B dense, ~20 tok/s on a 2-core box. Prompt-caching validated at 220× TTFT. Goal: maximize tok/s **and** token-efficiency **and** coding quality, cheaply.

---

## PART A — Composer techniques → transfer analysis

| # | Composer technique | What it is (cited) | Transfers to us? | Concrete analog / verdict |
|---|---|---|---|---|
| 1 | **MoE (active experts/token)** | MoE LM; only a subset of params active per token, keeping latency low while capacity stays large. Base Kimi K2.5 = 1.04T total / 32B active. ([Composer blog](https://cursor.com/blog/composer), [getaibook](https://getaibook.com/blog/cursor-composer-2-is-built-on-kimi-k2-5/)) | **YES — strongest transfer.** | CPU decode is bandwidth-bound: tok/s ≈ DRAM GB/s ÷ active-bytes-read-per-token. Only active experts stream per token, so a 30B-A3B decodes like a **~3B dense**, needing full 30B in RAM. ([MoE offload guide](https://huggingface.co/blog/Doctor-Shotgun/llamacpp-moe-offload-guide)) **Sweet spot for a bandwidth-bound box ≈ 2.4–3.5B active** (Granite-Tiny 1B = fastest but weaker code; 12B-active GLM-Air = too slow on CPU). Adopt. |
| 2 | **Low-precision kernels (MXFP8 MoE)** | Custom MXFP8 MoE kernels on Blackwell — faster inference without post-training quant. ([Composer blog](https://cursor.com/blog/composer), [Composer 2 report](https://cursor.com/blog/composer-2-technical-report)) | **Partially — different mechanism, same goal.** | Our analog = **GGUF quant choice + repacked CPU kernels**. Realistic: `Q4_K_M` / `Q5_K_M` baseline; evaluate **ik_llama.cpp** repacked quants (e.g. `IQ4_K`, `Q4_0_4_8` AVX2-repacked) for higher CPU throughput. We can't do native MXFP8 inference; we *can* match "small bytes/token × good kernel." Adopt the quant-eval, not MXFP8 literally. |
| 3 | **Agentic/tool-centric RL for token efficiency** ★ | Trained in the real Cursor harness (edit, semantic search, grep, run terminal/tests), with nonlinear/efficiency rewards to make efficient tool choices + maximize parallelism. ([Composer blog](https://cursor.com/blog/composer), [Composer 2 report](https://cursor.com/blog/composer-2-technical-report)) | **YES on the objective; PARTIAL on the method.** | **This is our headline lesson.** We can't replicate Cursor's RL infra (100k+ sandboxes, 5-hr live-feedback loop). Feasible path: **(a) SFT on curated *efficient* trajectories** — minimal edit-region diffs, jump-to-file over full reads, run-tests-then-stop, no redundant re-reads; **(b)** optional lightweight **GRPO/DPO** with reward = `task_pass − λ·token_count`. Data design is the real work (see "what to benchmark"). |
| 4 | **Self-summarization / compaction-in-the-loop** | Rollouts chain generations via learned summaries; at ~200k context the model compacts to ~1k tokens and continues; reward reinforces info-preserving summaries → **~50% fewer compaction errors at ~1/5 tokens** vs prompt-based summarization. ([philschmid](https://www.philschmid.de/kimi-composer-context), [essamamdani](https://www.essamamdani.com/blog/composer-25-cost-compression)) | **YES — high value, partial via SFT.** | Bake a **self-summarize action** into our agent harness + teach it in the QLoRA SFT set (include summarize→continue traces). Even prompt-engineered compaction helps today; the *learned* version is the upgrade. Directly attacks token-efficiency goal. |
| 5 | **Prompt / KV caching (cache-read)** | Built for low-latency recurring-harness loops; KV reuse of stable system prompt/harness. ([Composer blog](https://cursor.com/blog/composer)) | **YES — already validated.** | Our 220× TTFT prompt-cache **is** this. Confirmed match. Persistent one-model-per-box is ideal: keep system prompt + toolkit context KV-cached; matters more on CPU since MoE prefill touches more experts than decode. Keep + extend (cache toolkit/skill preambles). |
| 6 | **Strong open base + heavy continued training** | Composer 2 ≈ **25% base (Kimi K2.5) / 75% Cursor** continued-pretrain + RL; continued pretrain on code-heavy mix, mostly 32k seq, long-ctx extension to 256k, short SFT. ([emelia.io](https://emelia.io/hub/cursor-composer-2-review), [Composer 2 report](https://cursor.com/blog/composer-2-technical-report)) | **YES — this is our whole thesis.** | Pick the best *servable* open base, spend compute on **coding-specialized continued training**. For us: QLoRA on Workbooks DSL corpus. Implication: don't over-index on base benchmarks — a slightly-weaker base + strong domain fine-tune can win on *our* task. But a MoE base makes the served result cheaper. |

★ = key technique per the brief.

---

## PART B — Are we on the right base model?

Best current (June 2026) open, GGUF/llama.cpp-servable, commercially-licensed coding models for CPU, emphasis on small-active MoE.

| Model | Total / Active | License (commercial?) | Coding bench | GGUF | RAM @ Q4_K_M | CPU decode class | QLoRA maturity |
|---|---|---|---|---|---|---|---|
| **Qwen3-Coder-30B-A3B-Instruct** ★ | 30.5B / **3.3B** | **Apache-2.0 ✓** | SWE-bench Verified **~50–52%** ([HF disc #30](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct/discussions/30)) | ✓ Unsloth/bartowski | **~18.6 GB** ([Unsloth GGUF](https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF)) | ~12–30 tok/s (≈3B) | **Mature** — Unsloth FT in 17.5 GB VRAM ([docs](https://unsloth.ai/docs/basics/faster-moe)) |
| **Qwen3-Coder-Next (80B-A3B)** | 80B / **3B** | **Apache-2.0 ✓** | **SWE-bench Verified 70.6** ([SoftwareSeni](https://www.softwareseni.com/qwen3-coder-next-deepseek-v3-2-and-glm-4-7-which-open-weight-model-wins-for-coding-agents/)) | ✓ | **~45–48 GB** | ~12–30 tok/s (≈3B) | Mature (Qwen3-Next lineage) |
| **Qwen3.6-35B-A3B** | 35B / **3B** | **Apache-2.0 ✓** | beats Gemma-4-26B-A4B on coding ([Towards AI](https://pub.towardsai.net/i-tested-alibaba-qwen3-6-35b-a3b-30cc4658a382)) | ✓ | ~21 GB | ~12–30 tok/s | Mature |
| **DeepSeek-Coder-V2-Lite** | 16B / **2.4B** | DeepSeek Model License (custom, commercial-permitted, **not OSI**) | HumanEval **81.1**, MBPP+ 68.8 ([DEV](https://dev.to/jovan_chan_9500711396d4e6/best-local-coding-llm-in-2026-qwen25-coder-vs-deepseek-coder-v2-vs-codestral-45g8)); SWE-bench old-gen/low | ✓ ([bartowski](https://huggingface.co/bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF)) | **~10.4 GB** | ~12–30 tok/s | Workable, older arch |
| **Ling-Coder-lite** | 16.8B / **2.75B** | **MIT ✓** (data open too) | SOTA-for-size on 12 benches ([HF](https://huggingface.co/inclusionAI/Ling-Coder-lite)) | ✓ (mradermacher) | ~10–11 GB | ~12–30 tok/s | Good open FT base |
| **Granite-4.0-H-Tiny** | 7B / **1B** | **Apache-2.0 ✓** (ISO 42001) | HumanEval **83**, MBPP **80** ([HF](https://huggingface.co/ibm-granite/granite-4.0-h-tiny)); no SWE-bench | ✓ | **~4.5–5 GB** | **~30–80 tok/s** (fastest) | Unsloth-supported |
| **Granite-4.1-3B / 8B dense (current)** | 3B / 3B dense | **Apache-2.0 ✓** | general/enterprise; no agentic-coding SWE-bench | ✓ | ~2–5 GB | ~20 tok/s (measured) | Mature |
| **GLM-4.5-Air** | 106B / **12B** | MIT ✓ | SWE-bench **57.6** ([arXiv 2508.06471](https://arxiv.org/pdf/2508.06471)) | ✓ | ~60–65 GB | **~4–12 tok/s (too slow CPU)** | OK |

★ = recommendation.

### Recommendation: switch from Granite dense → Qwen3-Coder-30B-A3B-Instruct

For the **CPU + bare-metal-RAM-is-cheap** scenario, switch to a small-active coding MoE. **Primary pick: Qwen3-Coder-30B-A3B-Instruct.** Rationale:

- **Decode speed:** 3.3B active ⇒ same CPU decode class as our current 3B Granite (~the measured ~20 tok/s ballpark), but with materially higher coding quality. We trade RAM (which is cheap here) for capability at *no decode-speed cost*. ([MoE offload guide](https://huggingface.co/blog/Doctor-Shotgun/llamacpp-moe-offload-guide))
- **Quality:** ~50% SWE-bench Verified vs Granite-Tiny/3B having no competitive agentic-coding number — a real step up on *agentic* coding, which is our task. ([HF disc](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct/discussions/30))
- **License:** Apache-2.0, clean for commercial self-hosting. ([card](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct))
- **QLoRA:** Most mature MoE QLoRA path (Unsloth, router-layer handling). ([Unsloth MoE](https://unsloth.ai/docs/basics/faster-moe))
- **GGUF:** First-class.

**Tradeoffs to accept:**
- **RAM / cold-start:** ~18–22 GB resident at Q4 (vs ~5 GB for Granite-Tiny). Fine on bare metal; *persistent one-model-per-box* amortizes cold-start. Total params must fit even though only active stream.
- **Prefill latency:** MoE prefill touches more experts than decode → worse TTFT before cache. Mitigated by our validated prompt-cache (KV reuse of stable harness). Cache aggressively.
- **Spec-decode:** separate-drafter spec-decode won't help (3B-active leaves no cheap drafter; verify routes to many experts). Use **self-draft (EAGLE/Medusa-style) layers** like Composer if we chase the 2–3× — but that's a fine-tune project, not a config flag. ([philschmid](https://www.philschmid.de/kimi-composer-context), [mlx-lm #1132](https://github.com/ml-explore/mlx-lm/issues/1132))

**Keep Granite-4.0-H-Tiny (1B active) as the "fast tier"** for latency-critical / small-box deployments — ~30–80 tok/s, ~5 GB, spotless license. **Watch Qwen3-Coder-Next (80B-A3B, SWE 70.6)** for boxes with ≥64 GB RAM — frontier quality at the *same 3B-active decode cost* — and **Ling-Coder-lite (MIT)** as a fully-open fine-tune base if license purity or open data matters.

**Don't stay on Granite-3B dense** as the primary: it's a general/enterprise model with no agentic-coding edge, and a 3B-active MoE gives us much more capability at the same decode-speed class on hardware where RAM is the cheap resource.

---

## What to benchmark to decide (the empirical gate)

Don't switch on paper. Run, on one representative EPYC/AVX2 box, GGUF Q4_K_M, single-stream, prompt-cache on:

1. **Decode tok/s** — Granite-4.1-3B vs Qwen3-Coder-30B-A3B vs Granite-4.0-H-Tiny. Confirm 30B-A3B lands near the 3B class (target: within ~1.5× of Granite-3B). If far slower, AVX2 expert-gather is the culprit — test **ik_llama.cpp** repacked quants.
2. **Prefill / TTFT** — cold vs warm (prompt-cache). Quantify the MoE prefill penalty and the cache recovery (compare to our 220× number).
3. **RAM headroom** — 30B-A3B + 32k KV cache; confirm fits with margin; measure cold-start load time (matters even if persistent).
4. **Quality on OUR task** — a held-out Workbooks eval set (single-file HTML, `wb-*` Lit components, toolkit authoring, org-mode). Use the existing agent-eval harness (LLM judge). Compare base models *before* fine-tune to isolate base contribution.
5. **Token-efficiency (the headline)** — measure **tokens-per-completed-task**, not just pass-rate, on the eval set. Baseline each model, then re-measure after the trajectory-distillation QLoRA. Target a Composer-style step down (their compaction hit ~1/5 tokens). Make tokens-per-task a tracked metric in the eval harness alongside pass-rate.
6. **QLoRA loop cost** — time + VRAM to QLoRA each candidate on the Workbooks corpus; confirm Unsloth MoE path works end-to-end and the GGUF re-quantizes cleanly for CPU serving.
7. **(stretch) self-draft spec-decode** — only if (1) shows we want more tok/s; prototype EAGLE/Medusa heads, measure acceptance on our domain. Do *not* invest in separate-drafter spec-decode.

**Decision rule:** switch to Qwen3-Coder-30B-A3B if (a) decode stays within ~1.5× of Granite-3B, (b) RAM fits with margin, and (c) it beats Granite on the Workbooks quality eval pre-fine-tune. Otherwise fall back to Granite-4.0-H-Tiny (MoE, faster) before reconsidering dense.

---

## Sources

- [Composer: Building a fast frontier model with RL · Cursor](https://cursor.com/blog/composer)
- [A technical report on Composer 2 · Cursor](https://cursor.com/blog/composer-2-technical-report)
- [How Kimi, Cursor, and Chroma Train Agentic Models with RL · philschmid](https://www.philschmid.de/kimi-composer-context)
- [Composer 2.5 cost compression · Essa Mamdani](https://www.essamamdani.com/blog/composer-25-cost-compression)
- [Composer 2 review / Kimi K2.5 compute split · emelia.io](https://emelia.io/hub/cursor-composer-2-review)
- [How Cursor Built Composer 2 on Kimi K2.5 · getaibook](https://getaibook.com/blog/cursor-composer-2-is-built-on-kimi-k2-5/)
- [Composer · Simon Willison](https://simonwillison.net/2025/Oct/29/cursor-composer/)
- [Qwen3-Coder-30B-A3B-Instruct · HF](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct) · [GGUF](https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF) · [SWE-bench disc](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct/discussions/30)
- [Unsloth faster-MoE FT docs](https://unsloth.ai/docs/basics/faster-moe)
- [DeepSeek-Coder-V2-Lite GGUF · bartowski](https://huggingface.co/bartowski/DeepSeek-Coder-V2-Lite-Instruct-GGUF) · [paper](https://arxiv.org/html/2406.11931v1)
- [Ling-Coder-lite · HF](https://huggingface.co/inclusionAI/Ling-Coder-lite)
- [Granite-4.0-H-Tiny · HF](https://huggingface.co/ibm-granite/granite-4.0-h-tiny)
- [GLM-4.5 · arXiv 2508.06471](https://arxiv.org/pdf/2508.06471)
- [Qwen3-Coder-Next vs DeepSeek-V3.2 vs GLM-4.7 · SoftwareSeni](https://www.softwareseni.com/qwen3-coder-next-deepseek-v3-2-and-glm-4-7-which-open-weight-model-wins-for-coding-agents/)
- [Qwen3.6-35B-A3B · Towards AI](https://pub.towardsai.net/i-tested-alibaba-qwen3-6-35b-a3b-30cc4658a382)
- [llama.cpp MoE offload guide · HF blog](https://huggingface.co/blog/Doctor-Shotgun/llamacpp-moe-offload-guide)
- [SP-MoE speculative decoding · arXiv 2510.10302](https://arxiv.org/html/2510.10302v1) · [mlx-lm spec-decode on MoE #1132](https://github.com/ml-explore/mlx-lm/issues/1132)
