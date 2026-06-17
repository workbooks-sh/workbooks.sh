# Fine-Tuning a BitNet (1.58-bit Ternary) Model for a Narrow Domain, Served on CPU

Research report — 2026-06-16. Use case: a small, cheap, CPU-servable model specialized in our authoring concepts (Workbooks, Workponents, toolkits, org-mode), fine-tuned on rented GPU, served via `bitnet.cpp` on Fly microVMs.

## Executive summary (read this)

- **Yes, you can fine-tune a ternary BitNet model — but only via QAT, never PTQ.** Ternary weights are a forward-pass projection of full-precision *latent master weights*; training uses a straight-through estimator (STE). You cannot LoRA *into* the ternary weights, and you cannot just train an FP model and post-quantize to 1.58-bit — that destroys quality.
- **Two viable paths.** (a) Fine-tune the BF16 base, then re-run QAT/distillation to ternary (best retention, more DIY — see *BitNet Distillation*). (b) Continue QAT directly on a **pre-quantized** checkpoint with STE — this is the *only push-button-ish* path today, and it exists specifically for the **Falcon-Edge / Falcon3** family via TII's `onebitllms` + Axolotl.
- **Microsoft's BitNet stack is inference-only.** `bitnet.cpp` serves; it does not train. The real training tooling comes from TII (Falcon-LM `onebitllms`), HF Nanotron (research-grade), and Tether QVAC (frozen-base + FP16 adapters). LoRA that updates ternary weights is explicitly "an unexplored area of research."
- **Cost is not the obstacle.** A narrow-domain run on a 10B is **single-digit to low-hundreds of dollars** on rented GPUs. QAT is ~2-3× a plain SFT run (no PEFT shortcut). The obstacle is *quality retention through ternarization*, which is genuinely unproven for narrow specialists.
- **Verdict: do NOT ternary-fine-tune for this use case yet.** The published evidence (Falcon3-10B-1.58bit cratered on reasoning/math while keeping instruction-following) says specialization is at real risk through 1.58-bit. **Recommended: fine-tune a small FP model (Qwen2.5-3B) with QLoRA and serve it Q4 on CPU via llama.cpp.** Revisit ternary only if you outgrow CPU RAM/throughput budgets and have validated retention on a held-out authoring eval.

---

## 1. Can you fine-tune a 1.58-bit BitNet model?

**The core obstacle.** BitNet b1.58 is **Quantization-Aware Training (QAT)**, not post-hoc quantization. HF's docs state it plainly: BitNet models "need to be quantized during pretraining or fine-tuning because it is a Quantization-Aware Training (QAT) technique" ([HF transformers/bitnet](https://huggingface.co/docs/transformers/quantization/bitnet)). The ternary weights {-1,0,1} are a forward-pass projection of hidden **full-precision latent master weights**. Rounding to ternary is non-differentiable, so training uses a **straight-through estimator (STE)**: forward uses ternary, backward routes gradients straight to the FP latents as if rounding were identity — `x_quant = x + (activation_quant(x) - x).detach()` ([HF extreme-quantization blog](https://huggingface.co/blog/1_58_llm_extreme_quantization)).

**Why you can't LoRA on the ternary weights directly.** A frozen {-1,0,1} matrix has no useful gradient, and the information the model needs lives in the FP latents — which the *packed/deployed* checkpoint has thrown away. Naive quantization with no QAT is catastrophic: converting Llama3-8B to 1.58-bit makes the loss "start identically to random initialization (~13)... the model loses all of its prior information" ([extreme-quantization blog](https://huggingface.co/blog/1_58_llm_extreme_quantization)). A warm-up λ schedule ramping quantization strength recovers it (WikiText ppl 12.2 vs ~26 random init on 10B FineWeb-edu tokens).

**The two viable paths.**
- **(a) Train FP → QAT-distill to ternary.** The strongest current version is **BitNet Distillation (BitDistill)** ([arxiv 2510.13998](https://arxiv.org/abs/2510.13998)): converts an FP LLM to 1.58-bit *for a downstream task* via SubLN insertion + continual-pretrain warm-up + MiniLM-style attention distillation from the FP teacher. Claims "performance comparable to the full-precision counterpart... up to 10× memory savings and 2.65× faster inference on CPUs." **Best domain retention** because the FP teacher anchors the student. Downside: you implement it.
- **(b) Continue QAT directly on a pre-quantized checkpoint with STE.** This is what **Falcon-Edge enables** by releasing the latent master weights pre-divided by scale, so you can *resume* QAT: replace `nn.Linear` with `BitnetLinear`, full-finetune with STE in BF16, re-quantize. **Better-supported, lower-effort path today** for the Falcon-E / Falcon3 family.

**The exact Falcon3-10B-1.58bit pipeline.** Per the [Falcon-Edge blog](https://falcon-lm.github.io/blog/falcon-edge/) ([HF mirror](https://huggingface.co/blog/tiiuae/falcon-edge)): a single pretraining process simultaneously yields quantized and non-quantized variants (~1.5T tokens, WSD scheduler, LayerNorm removed inside BitNet layers, Triton kernels for `activation_quant`/`weight_quant`). They release **three variants**: bf16 non-BitNet, native ternary BitNet, and a **pre-quantized checkpoint engineered for fine-tuning** (`revision="prequantized"`). Falcon3-10B-1.58bit was produced by quantizing + continued-training the FP Falcon3 base under this scheme — i.e. path (b). **Reproducing it = resume QAT on the prequantized checkpoint with `onebitllms`.**

## 2. Tooling — what actually exists (push-button vs DIY)

| Tool | BitNet training? | Notes |
|---|---|---|
| **microsoft/BitNet** | **Inference only** | `bitnet.cpp` is the CPU reference impl; no training code. [repo](https://github.com/microsoft/BitNet) |
| **HF transformers** | No native training | Loads/runs BitNet; points to **Nanotron** for QAT. [docs](https://huggingface.co/docs/transformers/quantization/bitnet) |
| **HF Nanotron** | Yes (research-grade) | The actual path HF used for Llama3→1.58. DIY. [repo](https://github.com/huggingface/nanotron) |
| **onebitllms (TII)** | **Closest to push-button** | `replace_linear_with_bitnet_linear()` → SFTTrainer → `quantize_to_1bit()`. **Full-finetune only, no LoRA.** Falcon-E focus. [repo](https://github.com/tiiuae/onebitllms) |
| **Axolotl** | Yes, via onebitllms | `use_onebitllms: true`; Falcon-E-1B/3B + Falcon3-10B (experimental). "currently only full finetuning is supported." [docs](https://docs.axolotl.ai/docs/1_58bit_finetuning.html) · [blog](https://huggingface.co/blog/axolotl-ai-co/finetuning-ternary-llms-tii-axolotl) |
| **Unsloth / LLaMA-Factory** | No ternary QAT | — |
| **Tether QVAC Fabric** | Yes — first GPU LoRA for BitNet | **Frozen ternary base + FP16 LoRA adapters** (not true ternary-weight LoRA). [repo](https://github.com/tetherto/qvac-rnd-fabric-llm-bitnet) · [blog](https://huggingface.co/blog/qvac/fabric-llm-finetune-bitnet) |

**What Microsoft released vs withheld.** For `bitnet-b1.58-2B-4T` ([HF](https://huggingface.co/microsoft/bitnet-b1.58-2B-4T), [report arxiv 2504.12285](https://arxiv.org/abs/2504.12285)): trained from scratch in QAT. Released packed-1.58 (deploy), **BF16 master weights** ("use only for training/fine-tuning"), and GGUF. **Training code is withheld** — no fine-tuning recipe beyond "the BF16 variant exists." The "1-bit AI Infra" papers ([arxiv 2410.16144](https://arxiv.org/abs/2410.16144)) are inference infrastructure, not training releases.

**Maturity honestly.** *Production-leaning:* full FT of Falcon-E/Falcon3 via `onebitllms` + Axolotl (no LoRA). *Research-grade DIY:* QAT-from-FP via Nanotron; BitDistill (Oct-2025, best retention, you implement). *New/edge:* QVAC LoRA (frozen-base + FP16 adapter, young R&D repo). *Unproven:* LoRA that updates ternary weights — explicitly "an unexplored area of research."

## 3. GPU cost to fine-tune a 10B

**VRAM by path.** A 10B at BF16 is ~20 GB of weights; full FT needs ~10× once gradients + Adam states + activations are added → **~160-200 GB** (multi-GPU FSDP) ([llmhardware.io](https://llmhardware.io/guides/llm-fine-tuning-hardware-requirements)). **QLoRA** fits a 10B in **~11.6 GB** (single 24 GB card). **LoRA** ~30-40 GB (one 48/80 GB card). **QAT** has no PEFT shortcut — full forward+backward with fake-quant ops; naive 7B QAT needs >98 GB, training ~34% slower than full FT ([LR-QAT arxiv](https://arxiv.org/pdf/2406.06385); [Unsloth QAT](https://unsloth.ai/docs/blog/quantization-aware-training-qat)). **Rule of thumb: QAT ≈ full SFT + ~30-40%, i.e. 2-3× a LoRA/QLoRA run.**

**GPU-hours (5k-50k examples, 1-3 epochs).** LoRA/QLoRA on one A100: **~0.5-10 GPU-hr**. Full SFT (2-4 cards, ~2-3× per step): **~10-60 GPU-hr**. QAT: +~34% on full SFT ([io.net budget guide](https://io.net/blog/llm-fine-tuning-budget-guide-gpu-costs-timelines-and-what-to-spend)).

**Current rented prices (2025-2026, on-demand).** A100 80GB: RunPod **$1.39/hr**, Lambda $1.99-2.79, Modal ~$2.70. H100 80GB: RunPod **$2.69-2.89**, Lambda $3.29-4.29, Modal $4.29. Spot lower (RunPod spot H100 ~$1.19) ([Northflank](https://northflank.com/blog/runpod-gpu-pricing) · [Spheron 2026](https://www.spheron.network/blog/gpu-cloud-pricing-comparison-2026/) · [io.net](https://io.net/blog/llm-fine-tuning-budget-guide-gpu-costs-timelines-and-what-to-spend)).

**Total $ (RunPod cheap end).** QLoRA/LoRA: **~$1.50-30**. Full SFT: **~$30-250**. **QAT: ~$50-350** (the path you'd actually need for ternary). For a narrow domain, QLoRA at <$15 is the rational default *unless you specifically need a ternary artifact*.

## 4. Data corpus design

**Shape.** Instruction-response pairs, not raw completions. For an authoring DSL/framework mix: (1) NL-instruction → code ("write a Workponent that…" → `wb-*` Lit element); (2) infill/completion from real workbook/toolkit source; (3) error→fix and explain-this-code; (4) synthetic pairs by **reverse-prompting** (show a teacher real DSL output, ask it to write the instruction). Optimize for **semantic coverage** of every construct/idiom, not raw count ([coverage/depth arxiv](https://arxiv.org/pdf/2509.06463)).

**Size that moves a 10B.** Hundreds to low thousands, not tens of thousands. **LIMA**: 1,000 curated examples matched RLHF'd models — "almost all knowledge is learned during pretraining; only limited instruction tuning is necessary" ([arxiv 2305.11206](https://arxiv.org/abs/2305.11206)). Narrow-task gains concentrate at **100-300 samples**, stabilizing by ~300 ([arxiv 2310.05492](https://arxiv.org/pdf/2310.05492)). **Target ~500-2,000 high-quality, coverage-complete pairs.**

**Catastrophic forgetting.** Narrow SFT overwrites pretraining knowledge ([forgetting scaling arxiv](https://arxiv.org/html/2401.05605v1)). Mitigate with **replay**: cited ratios span 1% to 1:1; an adversarial-mix study found ≈25% general optimal. **Practical band: 10-20% general/replay data** mixed in; sweep it.

**Synthetic generation.** Self-Instruct seeding; **distillation from a stronger teacher** (high-leverage for a narrow domain — generate Workbooks/Workponents pairs with a strong model); **ROUGE-L dedup**; quality filtering via LLM-judge. **Crucially for a DSL: executable verification** — does the generated workbook/component *parse/build/render*? Use `wb` build + the eval harness as a hard correctness gate. That's the single strongest filter you have.

## 5. Re-quantize + deploy loop, and quality loss

**Conversion to `bitnet.cpp`.** `setup_env.py` orchestrates download → convert → quantize → kernel-codegen → compile. For a safetensors ternary checkpoint:
```bash
python ./utils/convert-helper-bitnet.py ./models/<bf16-ckpt>   # safetensors -> GGUF
python setup_env.py -md models/<model> -q i2_s
```
([microsoft/BitNet](https://github.com/microsoft/BitNet) · [DeepWiki model-prep](https://deepwiki.com/microsoft/BitNet/2.2-model-preparation)). **Quant types:** `i2_s` = 2-bit packing, portable x86+ARM; `tl1` = lookup-table, ARM/NEON; `tl2` = denser index, x86/AVX2, ~1/6 smaller than TL1 ([DeepWiki getting-started](https://deepwiki.com/microsoft/BitNet/2-getting-started)). For Fly x86 microVMs use **i2_s** (portable) or **tl2** (smaller).

**CPU performance.** ARM 1.37-5.07× speedup; x86 2.37-6.17×; a 100B b1.58 runs on a single CPU at **5-7 tok/s** ([arxiv 2410.16144](https://arxiv.org/abs/2410.16144)). The 2B model: **29 ms/token TPOT vs 41-124 ms** for FP peers, **0.4 GB** non-embedding memory ([arxiv 2504.12285](https://arxiv.org/html/2504.12285v1)). Note: "lossless" in the paper = kernel fidelity to the ternary weights, **not** zero quality cost vs FP.

**Quality loss — the crux.** BitNet is QAT-from-scratch, **not PTQ**. Direct evidence: PTQ'ing FP Qwen2.5-1.5B to INT4 (GPTQ/AWQ — *not even* as aggressive as ternary) "led to noticeable degradation," and native-ternary BitNet (avg 55.01) **beat** the INT4-PTQ Qwen (51.17-52.15) ([arxiv 2504.12285](https://arxiv.org/html/2504.12285v1)). **You cannot train FP and PTQ to 1.58-bit and keep quality — ternary-ness must be in the loop.**

**Does specialization survive ternary? Evidence is thin and the one real data point is discouraging.** No published study isolates "FP specialist → ternarize → retention." The closest real model is **Falcon3-10B-Instruct-1.58bit**, a QAT-*fine-tune* of FP Falcon3-10B ([model card](https://huggingface.co/tiiuae/Falcon3-10B-Instruct-1.58bit)). It cratered on reasoning/math vs the FP base ([FP card](https://huggingface.co/tiiuae/Falcon3-10B-Instruct)): BBH 44.82→**6.59**, MATH-L5 25.91→**2.44**, MUSR 13.61→**2.57**, GPQA 10.51→**4.27**. **Only IFEval (instruction-following) survived well (54.37).** So a QAT-fine-tuned 10B kept *surface instruction-following* but largely lost *reasoning*. For authoring (which is closer to structured instruction-following than to math reasoning) this is moderately encouraging — but it is a single, indirect data point, not proof.

## 6. Verdict and recommended pipeline

**Is ternary domain fine-tuning worth it here? Not yet.** The cost is fine; the *retention risk* is real and largely unproven, and the only turnkey path (Falcon3 + `onebitllms`, full FT no LoRA) is more expensive and riskier than the FP alternative — for a CPU-serve win that an FP Q4 model already mostly delivers.

**Compared alternatives:**
- **(i) Prompt/RAG the base BitNet** — cheapest, zero training, but a generic ternary 2B won't reliably emit correct `wb-*` / org-mode without strong retrieval; brittle for a DSL.
- **(ii) Fine-tune Qwen2.5-3B (FP), serve Q4** — **recommended.** QLoRA <$15, mature tooling, Q4 GGUF on CPU via llama.cpp is fast and small (~2 GB), and Q4 PTQ of an FP model is *well-understood and high-retention* (unlike ternary PTQ). You keep specialization with near-certainty.
- **(iii) LoRA on a non-BitNet small model** — same as (ii); the practical default.

**Recommended pipeline (~$10-30 total):**
1. **Build a ~500-2,000-pair corpus**: distill Workbooks/Workponents/toolkit/org-mode instruction→code pairs from a strong teacher; **hard-gate every example through `wb` build + the eval harness** (executable verification); 10-20% general-instruction replay; ROUGE-L dedup.
2. **QLoRA fine-tune Qwen2.5-3B-Instruct** on one RunPod A100 (~1-3 GPU-hr, **~$2-15**).
3. **Merge LoRA → export Q4_K_M GGUF** (llama.cpp `convert` + `quantize`).
4. **Serve on Fly CPU microVM** via llama.cpp (mirrors your existing `bitnet.cpp` experiment harness).
5. **Eval on a held-out authoring set.** Only if you later hit a hard RAM/throughput wall AND retention is validated, attempt the ternary path: reproduce Falcon3's pipeline (`onebitllms` resume-QAT on the prequantized checkpoint) or BitDistill, then `i2_s` GGUF for `bitnet.cpp`.

**Biggest risks:**
- **Ternary retention is unproven for specialists** — Falcon3-1.58bit lost most reasoning; treat any ternary result as proof-of-concept until eval'd.
- **You cannot PTQ to 1.58-bit** — any ternary path is full QAT (2-3× cost, full FT, no LoRA), not a cheap convert step.
- **Catastrophic forgetting** on a narrow corpus — mandatory replay + held-out general eval.
- **Synthetic-data quality** — without executable verification you train on broken DSL; the build gate is non-negotiable.
- **Tooling immaturity** — ternary FT is `onebitllms`/Axolotl-experimental or Nanotron-DIY; the FP/Q4 lane is boringly mature, which is exactly why it's the recommendation.

### Key sources
microsoft/BitNet [repo](https://github.com/microsoft/BitNet) · b1.58-2B-4T [report](https://arxiv.org/abs/2504.12285) · CPU infra [2410.16144](https://arxiv.org/abs/2410.16144) · HF QAT [docs](https://huggingface.co/docs/transformers/quantization/bitnet)/[blog](https://huggingface.co/blog/1_58_llm_extreme_quantization) · Falcon-Edge [blog](https://falcon-lm.github.io/blog/falcon-edge/) · `onebitllms` [repo](https://github.com/tiiuae/onebitllms) · Axolotl [1.58bit docs](https://docs.axolotl.ai/docs/1_58bit_finetuning.html) · BitDistill [2510.13998](https://arxiv.org/abs/2510.13998) · QVAC [repo](https://github.com/tetherto/qvac-rnd-fabric-llm-bitnet) · Falcon3-10B-1.58bit [card](https://huggingface.co/tiiuae/Falcon3-10B-Instruct-1.58bit) · LIMA [2305.11206](https://arxiv.org/abs/2305.11206) · RunPod pricing [Northflank](https://northflank.com/blog/runpod-gpu-pricing).
