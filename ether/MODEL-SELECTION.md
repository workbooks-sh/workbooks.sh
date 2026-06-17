# Model Selection — Small Open-Weight LLM for Workbooks DSL/Codegen (June 2026)

**Use case:** QLoRA fine-tune (~500–2000 instruction→code pairs) on a custom code-authoring task — authoring literate `.work` files (markdown + Elixir; code placed by `client`/`sandbox`/`server` keyword, compiled to WIT components) and toolkits (WIT packages of helpers). Then serve **Q4_K_M GGUF on CPU** (Fly.io shared/perf microVMs, 4–16 GB RAM, latency-tolerant, scale-to-zero). Priority signal: **code generation + strict instruction-following + structured/templated output**, NOT math-olympiad reasoning. Longish context helps (read example files, emit a full component).

---

## Executive Summary (read this)

- **The field moved hard in 2026.** Do not reach for Qwen2.5-3B. As of June 2026 the live small-model frontier is **Qwen3.5 (0.8/2/4/9/27B dense + 35B-A3B MoE, Feb–Mar 2026, Apache-2.0)**, **Gemma 4 (E2B/E4B/26B-A4B/31B, Apr 2 2026, Apache-2.0 — license finally fixed)**, **IBM Granite 4.1 (3/8/30B dense, Apr 29 2026, Apache-2.0)**, and **Mistral 3 / Ministral 3 (3/8/14B, Apache-2.0)**. ([Qwen guide](https://codersera.com/blog/qwen-3-5-complete-guide-2026/), [Gemma 4 blog](https://blog.google/innovation-and-ai/technology/developers-tools/gemma-4/), [Granite 4.1](https://research.ibm.com/blog/granite-4-1-ai-foundation-models), [Mistral 3](https://mistral.ai/news/mistral-3/))
- **A genuine QLoRA gotcha rules out the obvious pick.** Unsloth's own Qwen3.5 docs say plainly: *"It is not recommended to do QLoRA (4-bit) training on the Qwen3.5 models, no matter MoE or dense, due to higher than normal quantization differences."* So Qwen3.5 wants bf16-LoRA, not the 4-bit QLoRA the brief asks for. ([Unsloth Qwen3.5](https://unsloth.ai/docs/models/qwen3.5/fine-tune))
- **Cheap tier winner: IBM Granite 4.1-3B** — Apache-2.0, HumanEval 79.3 / EvalPlus 67.1, 128K ctx, runs in ~4 GB RAM, GGUF + llama.cpp supported, clean QLoRA path, and a code-and-enterprise instruction-following pedigree. The dense (non-hybrid) micro tier sidesteps the Qwen3.5 4-bit fragility. ([Granite 4.1 guide](https://www.aimadetools.com/blog/granite-4-1-complete-guide/))
- **Quality tier winner: IBM Granite 4.1-8B** (HumanEval 87.2, EvalPlus 80.2, BFCL-V3 68.3 tool-calling, 512K ctx, ~5 GB) — fits the same Apache-2.0/dense/QLoRA story one tier up. **Close runner-up / "if you can serve the RAM": Qwen3-Coder 30B-A3B or Qwen3.6-35B-A3B** — a small-active-param MoE (3B active) that serves at **~30 tok/s on modest hardware** despite ~18–20 GB RAM, the classic MoE-on-CPU sweet spot. Use it as the bf16-LoRA quality lane if Granite-8B underfits. ([Granite](https://www.aimadetools.com/blog/granite-4-1-complete-guide/), [Qwen3.6-35B-A3B @30tps](https://mychen76.medium.com/run-qwen3-6-35b-a3b-on-6gb-vram-using-llama-cpp-30-tps-a89032e5a60c))
- **Decision drivers, in order:** (1) Apache-2.0 license — all top picks qualify; (2) 4-bit QLoRA actually being recommended — knocks Qwen3.5 dense/MoE down for the *cheap 4-bit* lane; (3) dense CPU predictability for Fly microVMs; (4) coding + IFEval + structured-output standing.

---

## Comparison Table (realistic 2026 candidates, ~1.5B–8B + small-active MoE)

| Model | Sizes (cheap / quality) | Code & IF standing | License | QLoRA maturity | GGUF + CPU serving | Context |
|---|---|---|---|---|---|---|
| **IBM Granite 4.1** | 3B ✓ / 8B ✓ (+30B) dense | HumanEval 79.3/87.2/89.6; EvalPlus 67.1/80.2; BFCL-V3 60.8/68.3 (tool-call). Enterprise IF pedigree | **Apache-2.0** | Unsloth notebooks + LLaMA-Factory/Axolotl; clean QLoRA on dense | IBM-published GGUF + community; llama.cpp supported. 3B≈4GB, 8B≈5GB. Mamba-hybrid = ~70% less mem, 2× faster | 128K (3B) / 512K (8B) |
| **Qwen3.5** | 2/4B ✓ / 9B ✓ (+27B, 35B-A3B) | Qwen3-4B LCBv5 45.5, 8B 54.5; IFEval 81.2/83.0. 3.5 line stronger | **Apache-2.0** | Unsloth/LF support BUT **4-bit QLoRA explicitly NOT recommended** (quant-sensitive); use bf16-LoRA | GGUF export native (q4_k_m/q8_0); Q4 quality loss flagged by vendor | 256K |
| **Qwen3-Coder 30B-A3B / Qwen3.6-35B-A3B** | — / MoE 3B-active | Dedicated coder lane; SWE-bench-class agentic coding; 35B-A3B SWE-bench ~73 | **Apache-2.0** | Unsloth "Faster MoE" (17.5 GB VRAM); bf16-LoRA preferred (MoE 4-bit weak) | **~30 tok/s llama.cpp** on 6GB VRAM/32GB RAM; CPU-viable, RAM ~18–20GB. MoE 3B-active = fast despite size | 256K–1M (YaRN) |
| **Gemma 4** | E2B/E4B ✓ / 26B-A4B, 31B | E4B LiveCodeBench v6 52.0; 31B 80.0. Strong IF/multimodal | **Apache-2.0** (fixed; pre-4 was restrictive) | Unsloth Gemma-4 docs; **QLoRA on 26B-A4B MoE discouraged** (use 16-bit LoRA); E2B/E4B fine | Day-0 GGUF/llama.cpp; E-series effective-param (MatFormer/PLE) — confirm Q4 CPU path | 128K–256K |
| **Mistral 3 / Ministral 3** | 3B ✓ / 8B ✓ (+14B) dense | Ministral-3-3B-Reasoning LiveCodeBench 54.8; strong tool-calling | **Apache-2.0** | Broad (Mistral well-supported in all 3 trainers) | GGUF/llama.cpp standard; dense → predictable CPU | (per card) |
| **Phi-4-mini / -reasoning** | 3.8B ✓ / — (no 7–8B sibling) | HumanEval-strong for size; beats most 3B + some 8B (Qwen2.5 excepted); IFEval + HumanEvalPlus tuned | **MIT** | Supported; reasoning variant skews math | GGUF/llama.cpp standard; dense | 128K |
| **SmolLM3-3B** | 3B ✓ / — | Solid for 3B, fully open data; not a code specialist | **Apache-2.0** | Easy (small, conventional) | GGUF trivial; very light CPU | 128K |
| StarCoder2 / DeepSeek-Coder / Yi-Coder / OpenCoder / Codestral-mini | mixed | Strong code but **2024-era**; eclipsed by 2026 dense models on IF/structured output | mixed (Codestral = non-commercial MNPL) | varies | GGUF ok | varies |

*Cells cite the sources listed at the bottom.*

---

## Primary Recommendations

### Cheap tier (≈3–4B dense): **IBM Granite 4.1-3B** ✅

Why it wins for *this* task:

1. **License is unambiguous.** Apache-2.0, "fine-tune, deploy, and sell … without paying IBM anything." No Gemma-style carve-out history, no Llama acceptable-use clause, no Codestral non-commercial trap. ([Granite 4.1 guide](https://www.aimadetools.com/blog/granite-4-1-complete-guide/))
2. **4-bit QLoRA is actually viable here.** Unlike Qwen3.5 (vendor warns against 4-bit) and the Gemma-4/Qwen MoEs (Unsloth says use 16-bit LoRA, not QLoRA), Granite 4.1-3B is a **plain dense** model that takes a standard QLoRA recipe — exactly the 4-bit lane the brief specifies. ([Unsloth Qwen3.5](https://unsloth.ai/docs/models/qwen3.5/fine-tune), [Unsloth Gemma 4](https://unsloth.ai/docs/models/gemma-4/train))
3. **Coding + instruction-following standing.** HumanEval 79.3, EvalPlus 67.1, BFCL-V3 tool-calling 60.8 — strong for 3B, and Granite's lineage is enterprise instruction-following / structured output, which is precisely Workbooks' "emit a `.work` unit / valid WIT component" profile (not math reasoning). ([Granite guide](https://www.aimadetools.com/blog/granite-4-1-complete-guide/))
4. **CPU/Fly fit.** ~4 GB RAM, fits a shared/4-GB microVM; IBM publishes GGUF and llama.cpp runs it; the Mamba-hybrid design is *built* for low-memory, ~2× faster inference — ideal for scale-to-zero CPU serving. **128K context** comfortably reads example files + emits a full component. ([Granite GGUF/llama.cpp](https://biggo.com/news/202510031317_IBM_Granite_4.0_Community_Adoption))

*One caveat to verify (see Risks):* confirm your llama.cpp build has current Granite-hybrid (Mamba-2) kernels — historically the hybrid layers lagged plain-transformer support. If your microVM toolchain is pinned, validate the GGUF actually loads before committing.

### Quality tier (≈7–8B dense, or small-active MoE): **IBM Granite 4.1-8B** ✅ — MoE alternative noted

Why it wins:

1. **Same Apache-2.0 / dense / clean-QLoRA story, one tier up.** HumanEval **87.2**, EvalPlus **80.2**, BFCL-V3 **68.3** — and IBM notes the 8B "matches or beats the previous 32B-MoE Granite 4.0-H-Small," i.e. punches well above 8B. **512K context** is generous for multi-file Workbooks prompts. Still only ~5 GB → fits a 8–16 GB perf microVM at Q4_K_M with headroom. ([Granite guide](https://www.aimadetools.com/blog/granite-4-1-complete-guide/))
2. **Tool-calling/structured output is a first-class Granite strength** (BFCL-V3), which maps directly to emitting valid toolkit (WIT package) helpers / structured `.work` output.

**If Granite-8B underfits the DSL** (more likely on the *hardest* Workponents generation), step to a **small-active-param MoE — Qwen3-Coder 30B-A3B or Qwen3.6-35B-A3B**:

- **3B active params** means CPU decode speed of a ~3B model while carrying 30–35B of knowledge — the explicit MoE-on-CPU sweet spot. Real benchmark: **~30 tok/s in llama.cpp** on a 6 GB-VRAM / 32 GB-RAM box; pure-CPU is viable with ~18–20 GB RAM at Q4. ([Qwen3.6-35B-A3B @30tps](https://mychen76.medium.com/run-qwen3-6-35b-a3b-on-6gb-vram-using-llama-cpp-30-tps-a89032e5a60c))
- It is the **dedicated coder lane** (Qwen3-Coder), so raw codegen/agentic-coding is its best event.
- **Trade-off:** needs a 16-GB-class Fly microVM for RAM (not 4 GB), and you should **fine-tune with bf16-LoRA, not 4-bit QLoRA** (Unsloth flags MoE 4-bit as weak / BitsAndBytes-limited). So this lane costs you the "pure 4-bit QLoRA" simplicity in exchange for top-end code quality. ([Unsloth Qwen3.5](https://unsloth.ai/docs/models/qwen3.5/fine-tune), [Unsloth MoE](https://unsloth.ai/docs/models/qwen3.5/fine-tune))

**Net:** default both tiers to **Granite 4.1 (3B + 8B)** for the cleanest 4-bit-QLoRA→Q4_K_M-GGUF-on-CPU pipeline under Apache-2.0; keep **Qwen3-Coder 30B-A3B** in your back pocket as the "spend more RAM, train bf16-LoRA, get best code" quality escape hatch.

---

## Honorable Mentions / Watch List

- **Mistral 3 / Ministral 3 (3B + 8B, Apache-2.0).** A clean dense 3B+8B pair with strong tool-calling and broad trainer support — the most direct *alternative* to the Granite pair if Granite's Mamba-hybrid llama.cpp path gives you trouble. Verify its current code/IFEval numbers against Granite before switching. ([Mistral 3](https://mistral.ai/news/mistral-3/), [Ministral-3-8B](https://huggingface.co/mistralai/Ministral-3-8B-Instruct-2512))
- **Gemma 4 E4B (4.5B-effective, Apache-2.0 now).** Excellent IF/multimodal, day-0 GGUF; the E-series effective-param design is unusual for CPU — validate Q4_K_M throughput before relying on it. Avoid the 26B-A4B MoE for QLoRA (use 16-bit LoRA). ([Gemma 4 HF](https://huggingface.co/blog/gemma4), [Unsloth Gemma 4](https://unsloth.ai/docs/models/gemma-4/train))
- **Qwen3.5-4B / -9B (Apache-2.0).** Best-in-class small-model quality, BUT vendor-flagged **4-bit-QLoRA-fragile** — only choose if you'll train bf16-LoRA. ([Unsloth Qwen3.5](https://unsloth.ai/docs/models/qwen3.5/fine-tune))
- **Phi-4-mini (3.8B, MIT).** Strong HumanEval-for-size and permissive license, but **no 7–8B sibling** (breaks your two-tier plan) and the reasoning variant skews math, not DSL templating.
- **SmolLM3-3B (Apache-2.0).** Fully-open data, trivial to fine-tune/serve; a reproducibility-first fallback, not a code specialist.
- **2024-era code models (StarCoder2, DeepSeek-Coder, Yi-Coder, OpenCoder, Codestral-mini).** Eclipsed by 2026 dense models on instruction-following / structured output. **Codestral carries a non-commercial MNPL license — disqualifying.** Keep only as data/reference.

---

## Biggest Risks / Unknowns

1. **Granite Mamba-hybrid × llama.cpp build pinning.** Granite 4's hybrid Mamba-2 layers needed newer llama.cpp than plain transformers. IBM ships GGUF and llama.cpp "supports" it, but a **pinned Fly image could fail to load** the hybrid kernels. *Mitigation:* smoke-test the exact GGUF on your exact llama.cpp build before fine-tuning. If it fails, fall back to **Mistral 3** (plain transformer dense). ([Granite GGUF](https://github.com/IBM/gguf), [llama.cpp Granite](https://www.ibm.com/granite/docs/models/granite))
2. **Q4_K_M quality retention on a fine-tuned small model.** Vendors (Qwen especially) warn small models degrade more under aggressive quant. *Mitigation:* hold an eval set of real Workbooks/Workponents pairs; compare Q5_K_M vs Q4_K_M post-quant; bump to Q5 if the DSL grammar breaks.
3. **No published *CPU-only* tok/s for these exact models at Q4_K_M.** Numbers cited are mixed-hardware (e.g. 6GB-VRAM-assisted). Pure-CPU Fly throughput will be lower and **RAM-bandwidth-bound** — DDR channels matter more than core count for ≤8B. *Mitigation:* benchmark on the real microVM SKU before sizing.
4. **MoE RAM vs scale-to-zero economics.** The 30B-A3B sweet spot needs ~16–20 GB resident — larger cold-start footprint, slower scale-from-zero. Quantify whether the code-quality gain over Granite-8B justifies the bigger always-warm RAM bill.
5. **Chat-template / EOS drift.** Unsloth's universal warning: train and serve with the **same chat template + EOS**, or quality silently craters at inference. Lock the template into both the QLoRA config and the llama.cpp serving wrapper. ([Unsloth](https://unsloth.ai/docs/models/qwen3.5/fine-tune))
6. **Versioning is fast.** Qwen3.5→3.6 shipped inside ~2 months in 2026. Re-check the leaderboard before final lock; a Granite 4.2 or Qwen3.6-small could land mid-project.

---

## Sources

- Qwen 3.5/3.6 guide — https://codersera.com/blog/qwen-3-5-complete-guide-2026/
- Qwen3 technical report — https://arxiv.org/pdf/2505.09388
- Qwen3 blog — https://qwenlm.github.io/blog/qwen3/
- Unsloth Qwen3.5 fine-tune (QLoRA-not-recommended, GGUF export) — https://unsloth.ai/docs/models/qwen3.5/fine-tune
- Qwen3.6-35B-A3B @ ~30 tps llama.cpp — https://mychen76.medium.com/run-qwen3-6-35b-a3b-on-6gb-vram-using-llama-cpp-30-tps-a89032e5a60c
- Qwen3-Coder-Next (3B-active coder) — https://huggingface.co/unsloth/Qwen3-Coder-Next
- Gemma 4 blog (Google) — https://blog.google/innovation-and-ai/technology/developers-tools/gemma-4/
- Gemma 4 HF welcome — https://huggingface.co/blog/gemma4
- Gemma 4 guide (sizes/Apache-2.0/LCBv6) — https://codersera.com/blog/gemma-4-complete-guide-2026/
- Unsloth Gemma 4 train (MoE QLoRA caveat) — https://unsloth.ai/docs/models/gemma-4/train
- IBM Granite 4.1 (IBM Research) — https://research.ibm.com/blog/granite-4-1-ai-foundation-models
- Granite 4.1 guide (HumanEval/EvalPlus/BFCL/RAM/ctx) — https://www.aimadetools.com/blog/granite-4-1-complete-guide/
- Granite 4.0 GGUF + llama.cpp community — https://biggo.com/news/202510031317_IBM_Granite_4.0_Community_Adoption
- Granite hybrid Mamba-2 architecture — https://www.marktechpost.com/2025/10/02/ibm-released-new-granite-4-0-models-with-a-novel-hybrid-mamba-2-transformer-architecture-drastically-reducing-memory-use-without-sacrificing-performance/
- IBM GGUF repo — https://github.com/IBM/gguf
- Mistral 3 — https://mistral.ai/news/mistral-3/
- Ministral-3-8B-Instruct — https://huggingface.co/mistralai/Ministral-3-8B-Instruct-2512
- SmolLM3 / small-model comparison — https://www.bentoml.com/blog/the-best-open-source-small-language-models
- Phi-4-mini technical report — https://arxiv.org/pdf/2503.01743
- Fine-tuning frameworks 2026 (Unsloth/Axolotl/LLaMA-Factory) — https://www.spheron.network/blog/axolotl-vs-unsloth-vs-torchtune/
- CPU inference (llama.cpp, RAM bandwidth) — https://ceur-ws.org/Vol-4164/paper11.pdf
