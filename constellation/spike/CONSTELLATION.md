# The Granite Constellation — Ether's model system

**Commit: entirely the Granite 4.1 family.** Reason it won after a long search: mature in llama.cpp
(no bleeding-edge runtime walls), ONE shared tokenizer across the family (exact speculative decode),
Mamba-hybrid = CPU-optimized, an aLoRA/adapter ecosystem, a WebGPU/transformers.js path, Apache-2.0,
and an enterprise/code training domain that fits workbooks. Easiest thing to actually work with.

## The shift: not one model — a COMPOSABLE KIT
A constellation of Granite-family pieces, all speaking the same vocab, composed per-task / per-device
by the **Ether scheduler+router (already built in `nexus/lib/ether/`)**:

```
                    ┌──────────── Ether scheduler / router (BEAM, nexus) ────────────┐
                    │  routes task → piece; composes adapters; picks device lane      │
                    └─────────────────────────────────────────────────────────────────┘
   CPU verifier            GPU drafter             LoRA adapters           micro-models
 granite-4.1-8b/3b   Granite-vocab block-       (capabilities, hot-swap)  (modality lanes)
 (quality anchor,    diffusion drafter          RAG · safety · fn-call    vision · speech
  fast on CPU,       (DFlash recipe, SSM,        · USER-TRAINED domain     · embedding
  defines output)    4-bit, ~1-2GB, GPU)         adapters via aLoRA        · guardian
```

- **CPU verifier** — the output's quality anchor (exact-vocab verification). Fast on CPU.
- **GPU drafter** — the speed accelerator (see build plan below). Purpose-built, tiny.
- **LoRA adapters** — capabilities you compose: IBM's (RAG/safety/fn-call) + **user-trained domain
  adapters** (fine-tune on your workbook via the Ether pipeline). aLoRA = cheap runtime swap (shares
  base KV cache). This is the "fun, accessible" part: plug-and-play capabilities.
- **Micro-models** — specialized small Granites per modality (vision/doc, speech, embedding, guardian).

## The novel piece to BUILD: a Granite-vocab diffusion drafter (edge-optimized)
The one thing that doesn't exist yet — and it's cheap to make (you train ~5% of a model):
1. **Reuse Granite's frozen embedding + LM head** → exact Granite vocab by construction (kills the
   orphan-vocab problem; the drafter speaks Granite's tokens).
2. **Train a few BLOCK-diffusion intermediate layers** (KV-cacheable — the efficient class, not the
   slow full-masked Dream/DiffuCoder). Make them **SSM/Mamba** → linear-time, constant memory →
   ideal for CPU streaming + WebGPU memory caps. (Same component as the planned Mamba fusion head.)
3. **Self-distill from Granite** — run the verifier, collect (context → next-block) pairs, train the
   drafter to match. Free data. GPU-hours-to-days, low hundreds of $. The Ether fine-tune pipeline.
4. **4-bit QAT** → low-RAM, WebGPU-friendly.
Honest hard part: the MODEL is the easy 80%; **block-diffusion inference in WebGPU/CPU is immature**
(transformers.js does AR, not diffusion sampling) — custom denoise-loop kernels are the real
engineering. The model is weeks; the runtime is the research investment.

## One system, many deploy surfaces (the picture)
| Surface | Runtime | Notes |
|---|---|---|
| **Local desktop (Mac/PC)** | llama.cpp + Metal/CPU | works today; verifier+draft spec-decode |
| **Cloud / CUDA** | llama.cpp / vLLM | DFlash drafter is SOTA here today |
| **Browser / inside a workbook** | WebGPU (transformers.js/ONNX) | ship Granite + drafter + adapters INTO a workbook — dogfood: a workbook that runs its own models |
| **Edge / BEAM VM / WASM** | nexus Ether (Elixir) + sandbox | the scheduler orchestrates; models in the WASM/brokered lane |

## Build phases
- **P1 (now):** granite-4.1-8b verify + 3b draft, exact-vocab spec-decode on llama.cpp master. Baseline number.
- **P2:** train the Granite-vocab block-diffusion (SSM) drafter — the novel accelerator.
- **P3:** LoRA/aLoRA adapter system — IBM's + user-trained, hot-swap, via the Ether pipeline.
- **P4:** WebGPU deployment — Granite + drafter + adapters shipped in a workbook/browser container.
- **P5:** full constellation routed by the Ether scheduler across devices (CPU/GPU/web/edge).

## Why it's the moat
Nobody's built an efficient diffusion drafter for the enterprise/code Granite family. We'd own:
exact-vocab on-device speculative decode + composable adapters + a kit of micro-models, deployable
from a 16GB laptop to a browser tab to a BEAM/WASM edge VM — one family, all CPU-friendly, all ours.

# ═══ CONSTELLATION (renamed from Ether) — deployment tiers + client-extensible ML ═══

## Deployment tiers (one kit, four surfaces — verified substrates)
| Tier | Runtime (verified) | Granite payload | Billing |
|---|---|---|---|
| **Nano/browser/workbook** | **transformers.js v4 + WebGPU** (ONNX) | merged granite-4.0 350m/1b/micro (ONNX q4) — builds EXIST: `onnx-community/granite-4.0-*-ONNX-web` | client device |
| **Edge VM** | nexus Constellation (BEAM) + WASM sandbox | small Granite, brokered | per-use |
| **CPU cluster** | **Vultr 12-core, llama.cpp parallel slots** | granite-3b/8b, multi-agent, scale-to-zero | flat-rate/mo OR scale-to-zero+per-token on hosted weights |
| **GPU cloud** | vLLM/CUDA | DFlash diffusion drafter (SOTA here) | per-token |

## The hard architectural constraint (shapes everything)
**LoRA hot-swap + LLM fine-tuning = SERVER-TIER ONLY.** No browser stack does runtime LoRA
(transformers.js/WebLLM/wllama all merge-only) and none does in-browser LLM training. So:
- **Vultr/cloud server** = the heavy tier: LLM serving WITH runtime multi-adapter (llama.cpp
  `POST /lora-adapters` or vLLM), AND fine-tuning (PEFT LoRA on Granite, IBM's r=16/alpha=32).
- **Browser/workbook** = inference of MERGED models + CLASSICAL ML training (below).
- **Handoff:** train+merge LoRA on server → convert (Optimum ONNX int4 for transformers.js, or
  convert_hf_to_gguf Q4_K_M for wllama) → ship same-origin → run + OPFS-cache in the workbook.

## Client-extensible ML (the "train your own model in a workbook" platform)
Two substrates, split by what the client trains — both ride the EXISTING Rust→WASM compiler lane:
- **Classical ML (regression/clustering/trees/small nets): `smartcore` or `linfa` → Rust→WASM.**
  Genuinely TRAINS in-browser (pure CPU `fit()`), tiny wasm (~160–384KB), single-HTML-native,
  no JSON, no server. THE dogfood answer for user-facing "train a model in your workbook."
  (avoid linfa `blas` / smartcore `datasets` features for clean wasm.)
- **Small neural nets from scratch: TensorFlow.js `fit()` on WebGL** (WebGPU backend is
  inference-only — no training gradients). Transfer-learning ("Teachable Machine") = best UX.
- **LLM fine-tuning: server tier only** (PEFT/QLoRA on Vultr/cloud) → merge → ship merged. Never promise in-browser LLM training.

## Honest caveats (don't overpromise)
- ≤~3B models in-browser (2GB protobuf / 4GB wasm walls); WebGPU needs no headers but WASM threads do.
- WebGPU training doesn't exist (TF.js WebGL or Rust CPU only). ONNX-Runtime-Web training is deprecated.
- Browser Granite = 4.0 family confirmed (350m/1b/micro); IBM ships GGUF not ONNX (community ONNX exists).

# ═══ PIVOT (2026-06-18): LoRA adapters are the first-class product ═══
Dropped the dual-model speculative-diffusion drafter (DFlash PoC proved it needs real scale/GPU to
learn — toy-scale M4 training plateaus at chance; code validated, not the model). New core:
**Granite base + plug-and-play LoRA adapters, GPU as the local training station.**

## ✅ FULL ADAPTER PIPELINE VALIDATED end-to-end on M4 (dflash/lora_spike.py):
1. TRAIN: PEFT LoRA (r=16, q_proj/v_proj, 0.42% params) on granite-4.0-350m on the M4 GPU (MPS) —
   loss 3.2→0.17 in **9 seconds**. Taught it a fact the base didn't know.
2. CONVERT: PEFT → GGUF via llamacpp-src/convert_lora_to_gguf.py — **2.9 MB** adapter.
3. SERVE: llama-server -m granite-350m.gguf --lora constellation-lora.gguf (efficient CPU) →
   recalls the learned fact ("AURORA-SEVEN"); base-alone does not. HOT-LOADABLE.
→ Proves: train-on-GPU → serve-on-CPU, plug-and-play, tiny, fast, all on a laptop.

## Next (all buildable, mature pieces):
- Multi-adapter HOT-SWAP at runtime (llama-server POST /lora-adapters) = the "kit of skills".
- Self-learning loop: continual LoRA training as user data accumulates; snap into the running base.
- Scale base 350m→8b (more coherent standalone); aLoRA for cheap activation; per-domain adapters
  trained via the same pipeline = the user-extensible Constellation platform.

# ═══ UNBLOCK: train the 8B adapter LOCALLY via MLX QLoRA (2026-06-18) ═══
mlx_lm supports granite/granitemoe/granitemoehybrid + mlx_lm.lora (LoRA training on Apple Silicon).
KEY: train a LoRA on a 4-BIT quantized Granite base on the M4 GPU → fits because the base is 4-bit.
VALIDATED (350m): convert HF→MLX-4bit (mlx_lm convert -q --q-bits 4) then `mlx_lm lora --train` →
val loss 4.9→0.61, Peak mem 0.385GB, 900 tok/s, clean recall of the trained fact. The 8B-4bit
(mlx-community/granite-4.1-8b-4bit, 5.2GB) trains the same way → REAL 8B adapter trained locally, no
proxy/no-Vultr. bf16 path doesn't fit 16GB; the 4-bit MLX path does.
NOTE on "translate 350m → 8B LoRA": NOT possible (LoRA = delta to the 8B's exact weight shapes; a
standalone 350m can't reshape into it). But LoRA IS "a small thing attached to the big model" — that's
the mechanism the user was reaching for; train it directly via MLX QLoRA.
CONCURRENT GPU-train ‖ CPU-serve the 8B on M4: plausibly fits (4-bit MLX train 5.2GB + Q5 GGUF serve
6GB ≈ 11GB+overhead); the bf16 train path did NOT fit. Discrete-GPU server = trivially fits (separate
VRAM+RAM). Self-learning loop: CPU serves 8B, GPU QLoRAs adapter on 8B-self-generated curriculum,
hot-swap fresh adapter into serving (POST /lora-adapters). selflearn.py proves study→generate→train→know.

# ═══ CAPSTONE PROVEN: concurrent 8B GPU-train ‖ CPU-serve, LOCAL on 16GB M4 ═══
/tmp/capstone.sh ran: CPU serves granite-4.1-8b Q5 GGUF (-ngl 0) WHILE GPU QLoRA-trains an 8B adapter
on granite-4.1-8b-mlx-4bit (5.2GB) CONCURRENTLY. Both completed: server replied "OK" mid-training,
adapter saved (19MB), GPU train peak 5.49GB. Memory: 14% free at dual-load startup (tight, survived) →
57-77% free during run. Training slower under concurrency (3.4 vs 19 it/s — shared bandwidth) but WORKS.
→ The real 8B learns on GPU while serving on CPU, ENTIRELY LOCAL on a 16GB laptop. Discrete-GPU server
removes the tightness (separate VRAM+RAM). FULL Constellation validated: serve+train+concurrent+
self-learn+hot-swap-kit, all on Granite 4.1, all on the M4.

# ═══ TOOLKIT (kit/) + SELF-LEARN VALIDATED ON THE 8B (2026-06-18) ═══
Consolidated the validated spikes into kit/constellation.py — a real CLI: ask / train / self-learn / kit.
All-MLX (train QLoRA + serve adapters natively, no format conversion).
PROVEN end-to-end on the 8B: `self-learn` had granite-4.1-8b read an unseen field manual, self-generate
9 accurate Q&A pairs, train an adapter (400 iters), and recall PERFECTLY:
  VEGA-PRIME / green fox icon named Pixel / 35 milliseconds / `constellation revert --to last-stable`.
KEY HYPERPARAM BUG FOUND+FIXED: lr 3e-4 DIVERGES the 4-bit 8B QLoRA (degenerate "the the the" output;
also why the earlier capstone loss stuck at 5.7). lr 1e-4 → clean convergence (val loss 0.097), perfect
recall. Default LR lowered to 1e-4 in the toolkit. 350m tolerates 3e-4 (smaller, robust); 8B does not.
Nexus scheduler renamed Nexus.Ether -> Nexus.Constellation (223 tests green).

# ═══ DOGFOOD: real Nexus agent runs on the local Constellation 8B (2026-06-18) ═══
The actual Nexus.Agent loop (Llm -> model, bash tool-calling, wasm-kit sandbox, VFS, telemetry,
context mgmt) runs with its BRAIN = the local Granite 8B — no OpenRouter, no API key.
  serve:  llama-server -m granite-4.1-8b-Q5_K_M.gguf -ngl 0 --jinja  (GGUF bakes chat+tool template)
  agent:  Nexus.Agent.run(task: ..., base_url: "http://127.0.0.1:8103/v1/chat/completions",
                           model: "granite-4.1-8b-Q5_K_M.gguf")
PROVEN: "sort + count unique lines" -> {:ok, %{turns: 2, answer: "4"}} (correct; the agent tool-called
bash, ran sort/uniq in the wasm sandbox against /work/data.txt). The Llm base_url override + localhost
no-key (added earlier) is what makes the seam local. Runnable: ./run-local-agent.sh "<task>".
HONEST PERF: CPU-8B is ~5 tok/s; multi-turn tasks that need many turns can hit the wall-clock (a 4-turn
task timed out at 4 min) — raise timeout_ms or use the GPU/cloud lane for long-horizon runs.

# ═══ DOGFOOD: a SKILL adapter reachable through the Nexus runtime (2026-06-18) ═══
Nexus.Llm.complete (the runtime LLM seam) -> local llama-server serving a Granite GGUF base + a GGUF
LoRA adapter -> returns the adapter's self-taught fact ("AURORA-SEVEN"). Works via chat completions
AND raw — the GGUF chat template is fine (the earlier MLX-server miss was its missing template, not the
GGUF lane). Runnable: ./run-local-adapter.sh. llama-server also hot-swaps GGUF adapters live via
POST /lora-adapters — the "kit of swappable skills" at the serving tier.
ONE HONEST GAP (next): the 8B skill adapters are trained in MLX (QLoRA, fits 16GB); to serve them on the
llama.cpp GGUF lane (CPU + live hot-swap) they need MLX-adapter -> GGUF conversion (or fuse+convert).
The 350m proves the GGUF adapter lane end-to-end today; the 8B path = train-MLX/serve-MLX OR convert.

# ═══ PIVOT: ALL-GGUF, DROP MLX (2026-06-18) ═══
Decision (user): stop running MLX — go 100% llama.cpp/GGUF. WHY: cross-quant loss. A 4-bit-MLX-trained
8B adapter served on Q5 GGUF kept strong facts (VEGA-PRIME) but dropped weak ones — because train-lane
≠ serve-lane. Fix = train where you serve.
NEW ONE LANE: train = PEFT (HuggingFace, Mac GPU/MPS) -> convert_lora_to_gguf -> GGUF adapter;
serve = llama-server (matching GGUF base + adapter). Same arch both sides => clean transfer.
  - llama-finetune (llama.cpp native) is NOT viable: full FP32 finetune, WIP, 1B needs 24GB, saves the
    whole model (not an adapter). So PEFT is the trainer; llama.cpp is the server.
  - Toolkit rewritten to this lane (kit/constellation.py): ask/train/self-learn/serve/kit, all GGUF.
PROVEN clean same-lane (2026-06-18): self-learn -> 8B(GGUF) writes curriculum -> PEFT-trains a 350m
adapter -> GGUF -> serve 350m GGUF -> recall. VEGA-PRIME + Pixel recalled cleanly (no cross-quant gap).
THE LOCAL LIMIT IS CAPACITY, NOT THE LANE: the 8B curriculum was perfect (all facts incl "35ms" +
revert cmd), but the 350m is too small to hold them all (2/4 — confabulates the rest). => train on a
bigger base. Local PEFT fits ~1b/3b; 8B adapters train on a GPU (PEFT QLoRA) -> GGUF -> serve here.
MLX kept only as a legacy converter note; not used. The 8B remains the serving brain + curriculum author.

# ═══ LOCAL CAPACITY FINDING: small bases ≠ reliable fact-memorizers (2026-06-18) ═══
After the all-GGUF pivot, swept the local small-base lane for exact-fact recall (self-learn -> PEFT ->
GGUF -> serve), source = ops manual (VEGA-PRIME / Pixel-green-fox / 35ms / `constellation revert
--to last-stable` / Steward+Cartographer):
  - 350m, q/v LoRA r16, 8 pairs:            2/4 (VEGA-PRIME, Pixel; confabulates 35ms + cmd)
  - 1b,   q/v LoRA r16, 8 pairs:            3/5 (+ Steward; "42ms", "stardust revert")
  - 1b,   FULL-LINEAR r16:                  3/5, NUMBER now right (35) — full-linear > q/v for exact tokens
  - 1b,   FULL-LINEAR r32, 18-pair rich:    3/5 but CROSS-CONTAMINATION (over-reinforced VEGA-PRIME bled
                                            into other answers) — more data/rank can HURT.
CONCLUSION (robust, not a tuning bug): small bases (≤1b) memorize short salient facts (names) but
confabulate/cross-contaminate on numbers + long command strings from sparse self-generated data. The
RELIABLE fact-learner is the 8B (proven 4/4 in the MLX run). Defaults settled: full-linear r16, ~10-pair
curriculum. For reliable exact recall on the all-GGUF lane: train the 8B adapter on a GPU (PEFT QLoRA
fits 8B easily) -> GGUF -> serve here. Local small-base adapters = good for STYLE/skill/behavior shaping,
not arbitrary-string memorization. (8B PEFT doesn't fit 16GB locally; bitsandbytes 4-bit is CUDA-only.)

# ═══ HARD CONSTRAINT: LOCAL-ONLY, NO GPU/CLOUD (user, 2026-06-18) ═══
Strike the "GPU training station" tier entirely. Everything — serve AND train — runs on the user's own
computer. Consequence: the 8B can't fp16-train in 16GB, so the 8B is the SERVING BRAIN + the TEACHER
that generates curricula; adapters are AUTHORED on the biggest base that PEFT-trains locally = the 3B
(bf16 + gradient checkpointing fits 16GB). 1b/350m = edge/tiny adapters. All-GGUF, llama.cpp only.
Testing whether 3B clears the exact-fact bar the 1B missed (3/5). If 3B is good enough -> local-only
plan is complete. If facts still slip on 3B, reframe: local adapters = skill/style/behavior shaping
(what LoRA is genuinely good at), exact facts -> context/memory at serve time, not baked into the adapter.
