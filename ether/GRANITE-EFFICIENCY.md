# Granite 4.0 / 4.1 + CPU Inference-Speed Brief

**Scope:** GGUF on llama.cpp, CPU-only, AVX2 (no AVX-512/VNNI), Fly.io Firecracker shared-cpu microVM (~4–8 vCPU), **one microVM per invocation = strictly single-stream**. Task: code/DSL authoring (Workbooks/Workponents/toolkits/org-mode), longish context, QLoRA-fine-tuned. Baseline: Granite-3B-Q4_K_M ≈ **34 tok/s** gen @ 4 threads.

---

## Executive summary (highest-leverage first)

1. **Top speed win = speculative decoding with a tiny Granite drafter.** On a *compute-bound* CPU (ours: AVX2, no VNNI), a small drafter (a Granite-4.0-H-1B or the 3B drafting an 8B) verifies several tokens per expensive target pass. CPU is exactly the regime where this pays — unlike the GPU reports where it's memory-bandwidth-bound and nets zero ([HackMD](https://hackmd.io/ODXuOQNzSiyUITz7g9mtBw), [dev.to](https://dev.to/plasmon_imp/i-tried-speculative-decoding-on-rtx-4060-8gb-every-config-was-slower-than-baseline-1133)). Code/DSL is high-acceptance (repetitive syntax), the best case. Realistic **1.5–2×** decode on accepted-heavy output ([llama.cpp #21453](https://github.com/ggml-org/llama.cpp/issues/21453), [docs/speculative.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md)). **Benchmark this first.**
2. **4.0-vs-4.1 verdict:** for our 3B–8B code/instruction band, **Granite 4.1 8B dense** is the quality pick (its 8B *matches/beats* the 4.0 32B-MoE on HumanEval/MBPP and is a *cleaner QLoRA target* because it's homogeneous dense) — but **4.0-H-Micro 3B (hybrid)** is the *latency/throughput* pick because its Mamba-2 layers cut KV-cache and keep decode flat as context grows. See recommendation.
3. **Quantization: stay on Q4_K_M; do NOT switch to IQ-quants on this CPU.** I-quants decode *slower* on AVX2 (no inline GPU dequant) — they trade speed for size we don't need ([ik_llama #164](https://github.com/ikawrakow/ik_llama.cpp/discussions/164), [kaitchup](https://kaitchup.substack.com/p/choosing-a-gguf-model-k-quants-i)). Q4_K_M is the codegen sweet spot; Q5_K_M only if quality regresses post-QLoRA.
4. **KV-cache quant: Q8_0 yes, Q4_0 no.** `--cache-type-k/-v q8_0` is ~free quality and halves cache; **Q4_0 KV can be up to ~92% *slower* at long context** on CPU because dequant in attention swamps the saving ([NVIDIA forums](https://forums.developer.nvidia.com/t/kv-cache-quantization-benchmarks-on-dgx-spark-q4-0-vs-q8-0-vs-f16-llama-cpp-nemotron-30b-128k-context/365138), [smcleod](https://smcleod.net/2024/12/bringing-k/v-context-quantisation-to-ollama/)). Note: KV quant needs flash-attn, and **flash-attn does not apply to Mamba layers** — so this matters more for a dense 4.1 pick than a hybrid 4.0 pick.
5. **Thread tuning is real but small.** Set threads = **physical cores, not logical** — more threads than physical cores *drops* tok/s ([discussion #21112](https://github.com/ggml-org/llama.cpp/discussions/21112), [suhaib notes](https://notes.suhaib.in/docs/tech/latest/cracking-the-code-of-llamacpp-optimizing-threads-batch-size-and-context-for-peak-performance/)). On a shared-cpu Fly VM the "4 threads = 34 tok/s" is likely already near the knee; sweep 3/4/6/8 and pin.
6. **No engine is reliably faster than llama.cpp for our case.** PowerInfer needs a GPU; `ik_llama.cpp` can win on *some* CPU quants but is less maintained; IBM ships nothing faster for CPU GGUF. Don't chase a new runtime — spend the effort on spec-decoding + thread/batch tuning.

---

## PART A — Granite 4.0 + 4.1 complete map

**Architecture primer.** Granite 4.0 introduced a **hybrid Mamba-2/transformer** stack: a majority of Mamba-2 state-space (SSM) blocks interleaved with a few self-attention blocks at a **9:1 Mamba:transformer ratio**, and **NoPE** (no positional encoding) ([MarkTechPost](https://www.marktechpost.com/2025/10/02/ibm-released-new-granite-4-0-models-with-a-novel-hybrid-mamba-2-transformer-architecture-drastically-reducing-memory-use-without-sacrificing-performance/), [IBM Granite docs](https://www.ibm.com/granite/docs/models/granite)). The **"H" prefix = hybrid**; the non-H **Micro** is a conventional dense transformer kept for tooling that can't run Mamba. **Granite 4.1 walked the hybrid bet back: the main 3B/8B/30B line is dense decoder-only, homogeneous across sizes, no "H", no MoE** ([creativeainews](https://www.creativeainews.com/articles/ibm-granite-4-1-open-llm-512k-context-coding/), [research.ibm.com](https://research.ibm.com/blog/granite-4-1-ai-foundation-models)). **MoE is NOT dead in 4.1** — IBM published a separate **`granite-switch-4.1` MoE *preview*** line (3B/8B/30B-class) on HuggingFace, but it's preview, not the headline dense family ([huggingface.co/ibm-granite](https://huggingface.co/ibm-granite)). **Definitive resolution of the earlier fuzziness: the production Granite 4.1 instruct family is 100% dense transformer; 4.0 is where the hybrid-Mamba + MoE H-models live; 4.1 MoE exists only as the `granite-switch` preview.**

| Family | Variant | Total / Active | Dense vs MoE | Architecture | Ctx | GGUF | License |
|---|---|---|---|---|---|---|---|
| **4.0** | Micro | 3B / 3B | Dense | Conventional transformer | 128K | Yes | Apache-2.0 |
| **4.0** | **H-Micro** | 3B / 3B | Dense | **Hybrid Mamba-2/transformer (9:1)** | 128K | Yes | Apache-2.0 |
| **4.0** | **H-Tiny** | **7B / ~1B** | **MoE** (64 experts, 6 active) | **Hybrid MoE — 4 attn / 36 Mamba2 layers** | 128K | Yes | Apache-2.0 |
| **4.0** | **H-Small** | **32B / ~9B** | **MoE** | **Hybrid MoE (9:1)** | 128K | Yes | Apache-2.0 |
| **4.1** | 3B (base/instruct) | 3B / 3B | Dense | Dense decoder-only (40 layers, 2560 dim) | 128K | Yes | Apache-2.0 |
| **4.1** | **8B (base/instruct)** | **8B / 8B** | **Dense** | Dense decoder-only (40 layers, 4096 dim) | **512K** | Yes | Apache-2.0 |
| **4.1** | 30B (base/instruct) | 30B / 30B | Dense | Dense decoder-only (64 layers, 4096 dim) | 512K | Yes | Apache-2.0 |
| **4.1** | granite-switch-3B/8B/30B | preview | **MoE (preview)** | preview | — | partial | Apache-2.0 |

Sources for the table: H-Tiny layer/expert counts and 4.1 layer/dim figures — [creativeainews](https://www.creativeainews.com/articles/ibm-granite-4-1-open-llm-512k-context-coding/), [HF model card](https://huggingface.co/ibm-granite); lineup/active-params — [MarkTechPost](https://www.marktechpost.com/2025/10/02/ibm-released-new-granite-4-0-models-with-a-novel-hybrid-mamba-2-transformer-architecture-drastically-reducing-memory-use-without-sacrificing-performance/); context/license — [research.ibm.com](https://research.ibm.com/blog/granite-4-1-ai-foundation-models). (Exact total-param rounding: HF surfaces H-Micro ≈3B, the dense 4.0 `1b`/`h-1b` micro drafters also exist — useful as drafters, see Part B.)

**What changed 4.0 → 4.1.** Training: ~**15T tokens**, a five-phase pipeline + four-stage RL, with a *dedicated RL stage added to recover math* after RLHF regressed it ([aimadetools](https://www.aimadetools.com/blog/granite-4-1-complete-guide/)). Quality: the **dense 4.1-8B-instruct matches or beats the 4.0 32B-A9B MoE** on instruction-following and coding (HumanEval pass@1 ~85–87, MBPP ~82–87) ([aimadetools](https://www.aimadetools.com/blog/granite-4-1-complete-guide/), [rits.shanghai.nyu.edu](https://rits.shanghai.nyu.edu/ai/ibm-releases-granite-4-1-dense-8b-matches-prior-32b-moe-flagship/)). Architecture: **4.1 dropped hybrid Mamba for "predictable latency, stable token usage, and easier fine-tuning"** — IBM explicitly frames dense as the better QLoRA/downstream-tuning substrate ([creativeainews](https://www.creativeainews.com/articles/ibm-granite-4-1-open-llm-512k-context-coding/), [research.ibm.com](https://research.ibm.com/blog/granite-4-1-ai-foundation-models)). **For code/instruction at 3B–8B, 4.1-8B is the stronger model.**

**The hybrid Mamba-2 advantage (concrete, our case).** A transformer's KV-cache grows **linearly with context** (every past token's K/V stored per layer) and attention is **quadratic** in sequence length. Mamba-2 layers carry a **fixed-size recurrent state** instead of a growing cache, so the 9-in-10 Mamba layers contribute **~0 KV growth** and decode in **linear time**. IBM's headline: **>70% lower RAM and ~2× faster inference vs comparable transformers, specifically in long-context / multi-session** ([IBM docs](https://www.ibm.com/granite/docs/models/granite), [MarkTechPost](https://www.marktechpost.com/2025/10/02/ibm-released-new-granite-4-0-models-with-a-novel-hybrid-mamba-2-transformer-architecture-drastically-reducing-memory-use-without-sacrificing-performance/)). **For our single-stream CPU "read files → emit a component" task this matters two ways:** (a) RAM headroom on a small Fly VM (KV doesn't blow up as we stuff in file context), and (b) **decode tok/s stays flatter as the prompt grows** — a dense 3B *slows down* as context fills (bigger KV to scan each step), the hybrid largely doesn't. The catch: **the long-context win shrinks at short context**, and **llama.cpp's Mamba/SSM CPU kernels are less battle-tuned than its attention kernels**, so at *short* prompts a dense 3B can match or beat an H-3B on raw tok/s. Benchmark both at *your* real prompt lengths.

**MoE variants — CPU tradeoff.** H-Tiny is **7B resident / ~1B active** (64 experts, 6 active per token), H-Small **32B / ~9B**. On CPU, decode cost tracks **active** params, so H-Tiny *decodes like a ~1B model* — potentially **faster than the dense 3B** — while needing **~7B worth of RAM resident**. On a 4–8 GB-ish shared Fly VM, a Q4_K_M H-Tiny is ~4–4.5 GB resident, which fits. **So yes: H-Tiny is a credible "faster than dense 3B at higher quality" pick** *if* (a) the RAM fits and (b) llama.cpp's hybrid-MoE CPU path is efficient for you. **Caveat:** MoE adds expert-routing data movement that can hurt on bandwidth-thin shared VMs, and **speculative decoding interacts badly with MoE** (verification can activate different experts → extra movement) ([dev.to MoE note](https://dev.to/plasmon_imp/i-tried-speculative-decoding-on-rtx-4060-8gb-every-config-was-slower-than-baseline-1133)). So H-Tiny is great *standalone* but a poor *spec-decode target*.

---

## PART B — CPU single-stream optimization toolkit (ranked)

| # | Optimization | Expected single-stream win | Effort | Risk |
|---|---|---|---|---|
| 1 | **Speculative decoding, tiny Granite drafter** | **1.5–2× decode** on code (best case) | Med | Med — can net 0 if acceptance low |
| 2 | **Thread = physical cores, pin, `--mlock`** | 1.05–1.3× + stable | Low | Low |
| 3 | **Prefill batch tuning (`-b`/`-ub`)** → faster **TTFT** | TTFT 1.2–1.5× | Low | Low |
| 4 | **Right model: H-Tiny (1B-active) or H-Micro (flat long-ctx)** | model-dependent, can be ≥1.5× | Low | Med (RAM / kernel maturity) |
| 5 | **KV-cache `q8_0`** | RAM↓ ~50%, speed ~neutral | Low | Low (needs flash-attn; dense only) |
| 6 | **Keep Q4_K_M, avoid IQ on AVX2** | avoids a *regression* | Low | Low |

### 1. Speculative decoding (`-md` / `--draft-max` / `--draft-min`) — the big lever
The drafter cheaply proposes N tokens; the target **verifies all N in one batched forward pass** (batched compute is far cheaper per-token than sequential decode) ([docs/speculative.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md)). Flags: `-md <draft.gguf>`, `--draft-max` (default ~3–16) `--draft-min`. **Vocab/tokenizer MUST match** between drafter and target — **both must be Granite**, so a **Granite-4.0-H-1B or 4.0-1B** drafting a **4.1-8B** target works (same Granite tokenizer family — *verify the vocab hash matches* before trusting it). **Why CPU is the right home for this:** the widely-cited "speculative decoding gave 0 speedup" reports are **GPU, memory-bandwidth-bound** ([HackMD](https://hackmd.io/ODXuOQNzSiyUITz7g9mtBw)); CPU decode is **compute-bound** (slow AVX2 matmul per token), which is exactly the regime batched verification helps — and llama.cpp opened a **dedicated CPU spec-decode research track** for this reason ([#21453](https://github.com/ggml-org/llama.cpp/issues/21453)). **Code/DSL = high acceptance** (predictable syntax, boilerplate, our org-mode/Workponents structure), the best-case workload. Reported pair speedups 1.8–2.1× on GPU; expect a **more modest but real 1.5–2× on CPU for accepted-heavy codegen**. **Risk:** if acceptance is low or the drafter is too slow, you net ~0 — measure draft-acceptance-rate (llama.cpp prints it). **Do not use a MoE target here.**

### 2. Quantization for speed+quality on AVX2
- **Q4_K_M = recommended default.** ~4.8–4.9 bpw, the codegen sweet spot ([SitePoint](https://www.sitepoint.com/quantization-q4km-vs-awq-fp16-local-llms/)).
- **Q4_0** decodes slightly faster (simpler dequant) but **quality drops measurably** — not worth it for codegen.
- **Q5_K_M / Q6_K** = quality insurance if QLoRA output regresses; ~10–25% slower decode, larger RAM.
- **IQ4_XS & I-quants: AVOID on this CPU.** Smaller (~4.25–4.46 bpw) but **decode *slower* on AVX2** because I-quant dequant lacks the inline acceleration it gets on GPU ([ik_llama #164](https://github.com/ikawrakow/ik_llama.cpp/discussions/164), [kaitchup](https://kaitchup.substack.com/p/choosing-a-gguf-model-k-quants-i), [llama.cpp #5617](https://github.com/ggml-org/llama.cpp/discussions/5617)). We don't need the size saving; we'd pay tok/s for nothing.

### 3. KV-cache quantization (`--cache-type-k/-v`)
**`q8_0` = safe, ~free quality, halves KV RAM** ([smcleod](https://smcleod.net/2024/12/bringing-k/v-context-quantisation-to-ollama/)). **`q4_0` KV = avoid** — quality dips *and* at long context it can be **up to ~92% slower** on CPU (attention-time dequant overhead) ([NVIDIA forums](https://forums.developer.nvidia.com/t/kv-cache-quantization-benchmarks-on-dgx-spark-q4-0-vs-q8-0-vs-f16-llama-cpp-nemotron-30b-128k-context/365138)). **Two caveats for us:** (a) KV-quant **requires flash-attn**, and (b) **flash-attn / KV-quant only touch the attention layers — a Granite-4.0 *hybrid* has few of those**, so KV-quant is a *dense-4.1* optimization, largely moot on hybrid (the Mamba state isn't a KV cache).

### 4. llama.cpp CPU perf flags that move the needle
- **`--threads`: set to physical cores, not logical.** >physical *drops* tok/s ([#21112](https://github.com/ggml-org/llama.cpp/discussions/21112)). Sweep 3/4/6/8 on the actual Fly shape — the "34 tok/s @ 4" is likely near the knee on a shared-cpu VM; on shared vCPU you may even peak *below* the allotment.
- **`--batch-size` / `--ubatch-size` (prefill → TTFT):** bigger physical batch speeds **prompt processing / TTFT** (our "read files" prefill). Raise `-b`/`-ub` (e.g. 512→1024/2048) and measure TTFT; decode tok/s is unaffected.
- **`--flash-attn`:** helps attention prefill/decode and is required for KV-quant — **but only the attention layers; no effect on Mamba-2 blocks.** Use on dense 4.1; near-noop on hybrid.
- **`--mlock`** (+ `--no-mmap`): pin weights, avoid page-fault stalls / cache thrash on the small VM ([markaicode](https://markaicode.com/howto/how-to-configure-llamacpp-production-settings/)).
- **`--no-warmup`:** skips the empty warmup pass — **trims cold-start latency**, directly relevant since we spin **one microVM per invocation** (TTFT includes load). Trade: first real token slightly slower. Worth testing for our per-invocation model.
- **NUMA flags:** single shared-cpu Firecracker VM is effectively single-NUMA — **negligible**, skip.

### 5. Other engines — realistic
- **`ik_llama.cpp`** (ikawrakow fork): can beat upstream on *some* CPU quants/repacking; **less maintained, more setup risk** ([#164](https://github.com/ikawrakow/ik_llama.cpp/discussions/164)). Worth a single benchmark, not a migration.
- **PowerInfer / activation-sparsity:** **GPU-oriented**, no win for pure-CPU GGUF here. Skip.
- **IBM runtimes (vLLM hybrid support):** vLLM added first-class hybrid-Mamba support, but it's **GPU/batching-throughput** oriented — irrelevant to single-stream CPU ([PyTorch blog](https://pytorch.org/blog/hybrid-models-as-first-class-citizens-in-vllm/)).
- **Verdict:** stay on llama.cpp; the leverage is spec-decoding + flags, not a new engine.

### 6. Fine-tune (QLoRA) interactions
- **Dense (4.1) is the easier/cleaner QLoRA + re-quantize-to-GGUF target** — IBM explicitly cites this as a reason for going dense ([research.ibm.com](https://research.ibm.com/blog/granite-4-1-ai-foundation-models)). Hybrid-Mamba and MoE QLoRA tooling is thinner / more fragile.
- **Re-quantize after merge:** QLoRA → merge LoRA into base → convert to GGUF → quantize **Q4_K_M** (re-run an imatrix on your code/DSL data for best K-quant fidelity).
- **Spec-decoding × fine-tune:** if you fine-tune the *target*, **fine-tune (or at least keep) a matching drafter** — a drafter trained on the same code/DSL distribution **raises acceptance** and the spec-decode speedup. Keep target & drafter tokenizer/vocab identical (both Granite). **Don't fine-tune to a MoE if you want spec-decode.**

---

## RECOMMENDATION

**Pick — two-track, benchmark to decide:**
- **Quality track (default): Granite-4.1-8B-instruct, Q4_K_M**, QLoRA'd on Workbooks/Workponents/org-mode. Best code/instruction quality at the size; cleanest dense QLoRA target. Then **add a Granite small-model drafter (4.0-1B or 4.0-H-1B) for speculative decoding** — same Granite vocab, code = high acceptance. This is the configuration to beat.
- **Latency track (if 8B decode is too slow on the VM): Granite-4.0-H-Micro 3B, Q4_K_M** for flat long-context decode, **or Granite-4.0-H-Tiny (1B-active)** if its ~7B RAM fits — H-Tiny may *out-decode* the dense 3B at higher quality. (H-Tiny standalone only — not as a spec-decode target.)

**Apply optimizations in this order:** (1) thread=physical-cores + `--mlock` + `--no-warmup` (free, do today); (2) prefill `-b/-ub` tuning for TTFT; (3) **stand up speculative decoding with a Granite drafter — measure acceptance rate**; (4) if dense, add KV `--cache-type-k/-v q8_0` + `--flash-attn`; keep **Q4_K_M throughout, never IQ**.

## Open questions / things to benchmark
- **Spec-decode acceptance on *our* code/DSL** with 4.0-1B → 4.1-8B: print draft-acceptance; sweep `--draft-max 4/8/16`. Net win or wash? (decides #1).
- **Confirm tokenizer/vocab hash identical** between chosen Granite drafter and target before trusting spec-decode.
- **H-Tiny vs dense-3B decode tok/s** at *your* prompt lengths on the actual Fly shared-cpu shape — does the 1B-active MoE actually beat dense 3B given routing overhead on a bandwidth-thin VM?
- **Hybrid (H-Micro) vs dense (4.1-3B) decode at short *and* long prompts** — where's the crossover? (llama.cpp Mamba CPU-kernel maturity is the unknown).
- **Thread knee on shared-cpu Fly** — does 34 tok/s @4 improve at 6/8, or does shared-vCPU contention cap it lower?
- **`--no-warmup` cold-start delta** for the one-VM-per-invocation model: how much TTFT does it actually save vs first-token penalty?
- **Q4_K_M vs Q5_K_M quality after QLoRA** on codegen — does Q4_K_M hold, or do we need Q5 for DSL correctness?
