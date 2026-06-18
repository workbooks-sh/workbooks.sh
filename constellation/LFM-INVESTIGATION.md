# Liquid Foundation Models (LFM2) vs IBM Granite — CPU-Only Single-Stream Codegen Serving

**Date:** 2026-06-16
**Scope:** Evaluating LFM2 / LFM2.5 / LFM2-VL (and newer) as a candidate for our exact serving profile — GGUF on llama.cpp, CPU-only, AVX2, ~4 vCPU / 4 GB Fly Firecracker microVM, **single-stream** (one microVM per invocation, no batching), task = structured code/DSL authoring (Workbooks literate `.work` files — markdown + Elixir, WIT components, toolkits) with QLoRA fine-tuning. Frontrunner to beat: **Granite-4.1-3B/8B dense, Q4_K_M, ~34 tok/s @ 4 threads** on this CPU.

---

## Executive summary (lead with license + viability)

1. **License: conditionally viable, not freely viable.** LFM2 ships under the **LFM Open License v1.0** — Apache-2.0-derived **but with a hard $10M/yr revenue cap on commercial use**: *"Rights to use the model for commercial purposes end if your company's annual revenue exceeds $10 million USD"* ([liquid.ai/lfm-license](https://www.liquid.ai/lfm-license)). This is **not** open source by the OSI definition. Granite-4.x is **pure Apache-2.0, no revenue cap** ([HF: ibm-granite/granite-4-1](https://huggingface.co/blog/ibm-granite/granite-4-1)). For a startup under $10M this is a usable-today license; the moment we cross $10M we must negotiate a paid Liquid license — a permanent strategic liability baked into the product. **This alone makes LFM2 a worse default than Granite for a platform we intend to grow.**

2. **No published code benchmarks — anywhere.** The LFM2 blog, every HF model card, and the **arXiv technical report (2511.23404) all omit HumanEval/MBPP/MultiPL-E/LiveCodeBench entirely** ([arxiv.org/html/2511.23404v1](https://arxiv.org/html/2511.23404v1) — confirmed absent; pretraining is only ~5% code). They lead with IFEval, GSM8K, MMLU. For a model we'd pick *specifically for codegen*, the vendor's silence on code is a red flag. Granite publishes HumanEval ~79–82 (3B) / ~85–87 (8B) and MBPP ~61–71 / ~82–87 ([rits.shanghai.nyu.edu/Granite-4.1](https://rits.shanghai.nyu.edu/ai/ibm-releases-granite-4-1-dense-8b-matches-prior-32b-moe-flagship/)).

3. **The CPU-speed claim is real and large — but vs Qwen3, at small sizes.** LFM2-1.2B hits **2.3–2.8× prefill and 1.7–2.2× decode over Qwen3-1.7B** on CPU; on AMD Ryzen HX370, LFM2-1.2B = **99.7 tok/s decode @ 1K ctx, 89.0 @ 4K** vs Qwen3-1.7B's 60.8 / 38.5 ([Tech Report §2.4](https://arxiv.org/html/2511.23404v1)). This is a genuine architectural win for **TTFT and decode** on CPU. But the comparison is never against Granite, and the win comes partly from being *smaller* (1.2B vs our 3B/8B).

4. **First-class llama.cpp/GGUF support is real and merged.** LFM2 text models landed via **[PR #14620](https://github.com/ggml-org/llama.cpp/pull/14620)** (`ShortConv` op + GGUF convert/quant), runs on stock llama.cpp, official Liquid GGUFs exist. Caveats: a known imatrix-generation bug ([#14979](https://github.com/ggml-org/llama.cpp/issues/14979)) and the hybrid conv state complicates speculative decoding (below).

5. **Verdict in one line:** LFM2 is a **plausible faster-but-smaller complement**, not a clean Granite replacement. Its decode/TTFT edge is attractive for our single-stream CPU box, but the **$10M license ceiling + zero published code numbers + spec-decode friction** mean it cannot displace Apache-2.0 Granite as the default without us running our own codegen benchmark first.

---

## 1. License — the gating question

| Term | LFM Open License v1.0 | Granite 4.x |
|---|---|---|
| Base | "based on Apache 2.0 (with only a few changes)" | Apache-2.0 (unmodified) |
| Commercial use | **Free only if company annual revenue < $10,000,000 USD** | Unrestricted |
| Over threshold | *"Any Commercial Use … by a Legal Entity that exceeds the Threshold is not licensed under this Agreement"* → must contact Liquid for a paid license | N/A |
| Fine-tunes | Can keep proprietary, no copyleft | Same |
| Attribution | Must retain copyright/patent/trademark/attribution notices | Same |
| Termination | *"terminate automatically and immediately if You fail to comply"* | Standard Apache |

Source: [liquid.ai/lfm-license](https://www.liquid.ai/lfm-license), [docs.liquid.ai model-license](https://docs.liquid.ai/lfm/getting-started/model-license), [Liquid AI on X](https://x.com/LiquidAI_/status/1943294753384120427).

**Verdict:** Usable today under $10M; a hard commercial ceiling above it. This is a **source-available / "open-weight"** license, **not** OSI-open-source. For a product platform we plan to scale, Granite's clean Apache-2.0 is strictly safer.

## 2. Architecture & why "CPU-optimized"

LFM2 is a **hybrid Liquid backbone**: **16 blocks = 10 double-gated short-range convolution blocks ("LIV" / Linear Input-Varying operators) + 6 grouped-query-attention (GQA) blocks**, each with SwiGLU + RMSNorm ([LFM2 blog](https://www.liquid.ai/blog/liquid-foundation-models-v2-our-second-series-of-generative-ai-models), [Tech Report](https://arxiv.org/abs/2511.23404)). The block mix was chosen by **hardware-in-the-loop architecture search** optimizing the latency/quality/memory Pareto frontier on CPUs/NPUs.

**Why fast on CPU/edge:** Replacing most attention layers with **gated short convolutions** means:
- **Far less KV-cache** — only 6 of 16 layers carry a KV cache; conv blocks use a tiny fixed-size state, not a context-length-growing cache. Report: selected architectures *"lower peak RSS at long context (4K/32K), consistent with reduced KV-cache versus attention-heavy layouts"* — though **this is stated qualitatively, not quantified** ([Tech Report §2.1](https://arxiv.org/html/2511.23404v1)).
- **Short convs are cheap, cache-friendly integer/SIMD ops** well-suited to embedded SoC CPUs, vs O(n) attention scans over a growing KV cache.
- **Quantified speedup:** up to **2× prefill+decode vs similarly sized models**; concretely **2.3–2.8× prefill / 1.7–2.2× decode vs Qwen3-1.7B** on Galaxy S25 and Ryzen HX370 ([Tech Report §2.4](https://arxiv.org/html/2511.23404v1)). Baseline is **Qwen3, never Granite.**

Newer scale-ups keep the same backbone: **LFM2-8B-A1B** (8.3B total / 1.5B active MoE, 32 experts, top-4) claims *"3–4B-class quality at ~1.5B-class decode cost"* ([Tech Report §2.3](https://arxiv.org/html/2511.23404v1)); **LFM2-24B-A2B** extends it further ([liquid.ai/blog/lfm2-24b-a2b](https://www.liquid.ai/blog/lfm2-24b-a2b)).

## 3. Sizes & GGUF / llama.cpp support

**Dense sizes:** 350M, 700M, 1.2B, 2.6B. **MoE:** 8B-A1B (1.5B active), 24B-A2B. **Reasoning:** LFM2.5-1.2B-Thinking. All **32K context**, vocab **65,536**, bf16 ([HF cards](https://huggingface.co/LiquidAI/LFM2-1.2B), [Tech Report](https://arxiv.org/abs/2511.23404)).

**llama.cpp:** **First-class and merged** — text models via [PR #14620](https://github.com/ggml-org/llama.cpp/pull/14620) (adds `ShortConv` op + GGUF convert/quantize). Official `LiquidAI/LFM2-*-GGUF` repos + bartowski quants exist. Runs on **stock llama.cpp today** (not a fork). LFM2-VL added GGUF support separately ([Labonne/LinkedIn](https://www.linkedin.com/posts/maxime-labonne_lfm2-vl-now-supports-gguf-and-llamacpp-activity-7363142771638947841-tsV9)).

**Gotchas:**
- **Chat template** is ChatML-like with custom special tokens: `<|startoftext|>`, `<|im_start|>`, `<|im_end|>`, plus tool tokens `<|tool_list_start|>` / `<|tool_call_start|>` / `<|tool_response_start|>` — must wire the template correctly or instruction-following degrades.
- **Known bug:** imatrix generation fails — *"inconsistent size for blk.0.shortconv.in_proj.weight"* ([#14979](https://github.com/ggml-org/llama.cpp/issues/14979)). Affects imatrix-guided quant; plain Q4_K_M is fine.
- Custom `ShortConv` op = newer/less-battle-tested kernel path than Granite's well-worn attention path.

## 4. Quality for CODE / instruction-following

**Instruction-following is genuinely strong for the size** — LFM2-1.2B **IFEval 74.89** (> Qwen3-1.7B 73.98, ≫ Llama-3.2-1B 52.39); LFM2-2.6B **IFEval 79.56** ([HF LFM2-1.2B](https://huggingface.co/LiquidAI/LFM2-1.2B), [HF LFM2-2.6B](https://huggingface.co/LiquidAI/LFM2-2.6B)). That matters for our strict-DSL/structured-output requirement.

**Code: unmeasured by the vendor.** No HumanEval/MBPP/MultiPL-E/LiveCodeBench anywhere (blog, all cards, the arXiv report). Pretraining is only **~5% code** ([Tech Report §3.1](https://arxiv.org/html/2511.23404v1)). LFM2.5-1.2B-Thinking's blog *mentions* "programming" as a strength and claims it matches/exceeds Qwen3-1.7B on reasoning with 40% fewer params, but still **publishes no code pass@1** ([liquid.ai/blog/lfm2-5-1-2b-thinking](https://www.liquid.ai/blog/lfm2-5-1-2b-thinking-on-device-reasoning-under-1gb)).

**Skeptical read:** this fits the classic edge-model profile — strong IFEval/general/math, code ability untested and likely traded down for size. **Granite is explicitly code-tuned** with published numbers (HumanEval 3B ~79–82 / 8B ~85–87; MBPP 3B ~61–71 / 8B ~82–87, [Granite 4.1](https://rits.shanghai.nyu.edu/ai/ibm-releases-granite-4-1-dense-8b-matches-prior-32b-moe-flagship/)). **For codegen, Granite is the known quantity; LFM2 is an unverified bet.**

## 5. Measured CPU inference speed

Real numbers (llama.cpp, Q4_0/INT8), from [Tech Report §2.4](https://arxiv.org/html/2511.23404v1) and [LFM2.5-Thinking blog](https://www.liquid.ai/blog/lfm2-5-1-2b-thinking-on-device-reasoning-under-1gb):

| Platform | Model | Decode tok/s | Notes |
|---|---|---|---|
| AMD Ryzen HX370 (laptop CPU) | LFM2-1.2B | **99.7 @1K / 89.0 @4K** | vs Qwen3-1.7B 60.8 / 38.5 |
| Galaxy S25 (Snapdragon) | LFM2-1.2B | 69.8 @1K / 55.5 @4K | vs Qwen3-1.7B 39.7 / 26.9 |
| Apple M4 Pro (INT8) | LFM2.5-1.2B | 96 | |
| Snapdragon 8 Elite (Q4_0) | LFM2.5-1.2B | 70 | |

**Does it beat our Granite-3B baseline (~34 tok/s @ 4 threads, Q4_K_M)?** **Almost certainly yes on raw decode — but mostly because LFM2-1.2B is less than half the params of Granite-3B**, plus the conv-hybrid edge. No same-CPU, same-quant, **LFM2-vs-Granite** number exists publicly, and **our exact box (AVX2-only, no AVX-512, 4 vCPU)** is weaker than the Ryzen HX370 used in the report — so treat the absolute figures as upper bounds. The **architectural TTFT/prefill win (2.3–2.8×) is the most transferable claim** and directly helps our cold-start + first-token latency.

## 6. Fine-tuning (QLoRA)

- **Liquid ships official SFT+DPO notebooks for TRL and an Unsloth LoRA notebook** on the model cards ([HF LFM2-1.2B](https://huggingface.co/LiquidAI/LFM2-1.2B)). **No first-party Axolotl/LLaMA-Factory** mention (community paths likely but unverified).
- LFM2 is **integrated into HF Transformers** (`model_doc/lfm2`), so standard PEFT/QLoRA over the conv-hybrid works through the normal stack.
- **Re-quantize-to-GGUF path** works via the merged convert script — but watch the **imatrix bug ([#14979](https://github.com/ggml-org/llama.cpp/issues/14979))**; plain Q4_K_M re-quant of a merged adapter is the safe path, imatrix quant may need a workaround.
- **Risk:** LoRA targeting on `shortconv` projection layers is less documented than attention/MLP LoRA; expect to tune which modules get adapters. Granite (standard transformer-ish + Apache) has a more trodden QLoRA path.

## 7. Speculative decoding compatibility

- **Vocab match is easy:** all LFM2 dense sizes share vocab **65,536**, so **LFM2-350M could draft for LFM2-1.2B/2.6B** — the same-vocab requirement is satisfied ([HF cards](https://huggingface.co/LiquidAI/LFM2-350M)).
- **But the hybrid conv state fights llama.cpp spec-decode.** llama.cpp's speculative path assumes transformer KV semantics; for **recurrent/conv/hybrid models the draft must recompute conv/SSM state for accepted tokens**, which is harder and historically buggy — see the recent fix *"speculative decoding broken on hybrid SSM/MoE"* ([PR #20075](https://app.semanticdiff.com/gh/ggml-org/llama.cpp/pull/20075/overview)) and the general caveat that linear-RNN/hybrid models are *"less amenable to speculative decoding"* ([speculative.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md), [Mamba-in-Llama](https://arxiv.org/html/2408.15237v4)).
- **Net:** LFM2 spec-decode on llama.cpp is **possible but immature** — exactly the friction our **Granite-dense + tiny-Granite-drafter** plan avoids. And since LFM2-1.2B already decodes fast, the *marginal* benefit of stacking spec-decode on it is smaller than on a slower 8B.

---

## Comparison table

| Dimension | LFM2-1.2B | LFM2-2.6B | LFM2-8B-A1B (MoE) | **Granite-4.1-3B** | **Granite-4.1-8B** |
|---|---|---|---|---|---|
| License | LFM Open v1.0 ($10M cap) | same | same | **Apache-2.0** | **Apache-2.0** |
| Params | 1.2B | 2.6B | 8.3B/1.5B active | 3B dense | 8B dense |
| Arch | conv-hybrid (10 conv + 6 GQA) | same | hybrid + MoE | hybrid/dense | dense |
| Context | 32K | 32K | 32K | up to 512K | up to 512K |
| GGUF/llama.cpp | merged ([#14620](https://github.com/ggml-org/llama.cpp/pull/14620)), imatrix bug | same | newer | mature, first-class | mature, first-class |
| Code bench | **none published** | **none published** | **none published** | HumanEval ~79–82 / MBPP ~61–71 | HumanEval ~85–87 / MBPP ~82–87 |
| IFEval | 74.89 | 79.56 | — | ~82.30 | ~87.06 |
| CPU decode tok/s | ~90–100 (HX370) | (smaller→faster than 3B) | ~1.5B-class | **~34 (our box, baseline)** | slower than 3B |
| QLoRA | TRL+Unsloth notebooks; conv LoRA less documented | same | same | mature, standard | mature, standard |
| Cold-start (Q4 size) | ~0.7–0.8 GB ✅ smallest | ~1.5 GB | ~5 GB total weights | ~2 GB | ~5 GB |

(Granite code/IFEval: [Granite 4.1 summary](https://rits.shanghai.nyu.edu/ai/ibm-releases-granite-4-1-dense-8b-matches-prior-32b-moe-flagship/), [HF Granite 4.1](https://huggingface.co/blog/ibm-granite/granite-4-1). LFM2 figures cited inline above.)

---

## Verdict

**LFM2 does not cleanly beat Granite for our single-stream CPU codegen case — it is a possible faster, smaller *complement*, gated behind a license ceiling and an unverified code-quality question.**

- **Where LFM2 wins:** raw CPU **decode tok/s and TTFT/prefill** (the conv-hybrid is genuinely faster and lighter on KV-cache → better cold-start, smaller RAM, faster first token in our 4 GB box), and **IFEval/instruction-following** is strong — relevant to strict DSL output. LFM2-1.2B at ~0.7 GB Q4 is the best cold-start story here.
- **Where Granite wins (and why it stays the default):** **clean Apache-2.0 (no $10M trap), published and strong code benchmarks, mature QLoRA, and a clean spec-decode story** with a same-family drafter. For a *codegen* model on a *growing platform*, those are the decisive axes.
- **Recommendation:** Keep **Granite-3B as the production default.** Treat **LFM2-1.2B / LFM2-2.6B as challengers to benchmark**, not adopt sight-unseen. If our own eval shows LFM2-2.6B matching Granite-3B on Workbooks/Lit codegen at materially higher tok/s, it becomes a compelling **low-latency tier for sub-$10M deployments** — with a documented migration-to-Granite escape hatch for when we cross the revenue line.

## Open questions / what to benchmark to decide

1. **Run our own code eval** (HumanEval+/MBPP+ **plus a Workbooks `.work` literate-file held-out set**) for LFM2-1.2B, LFM2-2.6B vs Granite-3B/8B, Q4_K_M. This is the missing number that decides everything — the vendor won't give it to us.
2. **Same-box CPU bench:** LFM2-2.6B vs Granite-3B on the **actual AVX2-only, no-AVX-512, 4-vCPU Fly microVM** — measure decode tok/s *and* TTFT at 1K/4K/16K context. Confirm the conv-hybrid prefill edge survives AVX2-only (the report used Ryzen HX370, likely AVX-512-capable).
3. **QLoRA reality check:** fine-tune LFM2-2.6B on our DSL corpus via TRL/Unsloth, confirm `shortconv` LoRA targeting works, then re-quant to Q4_K_M GGUF and verify quality holds (and whether the imatrix bug [#14979] blocks imatrix quant).
4. **Spec-decode trial:** test LFM2-350M drafting LFM2-1.2B/2.6B on current llama.cpp — does the hybrid-state path actually accelerate, or hit the [#20075]-class bugs? Compare net tok/s to plain Granite-dense + Granite-drafter.
5. **Memory headroom:** measure peak RSS at 16K–32K context in 4 GB — the claimed KV-cache reduction is the one unquantified LFM2 advantage and is exactly what matters in a 4 GB microVM.
6. **License runway:** confirm with legal whether the $10M-revenue clause is per-entity/per-affiliate and whether a paid Liquid license is even available + at what cost, before betting any production tier on it.
