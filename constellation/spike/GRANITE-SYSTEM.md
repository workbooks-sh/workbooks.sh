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
