# Constellation kit

A Granite base + plug-and-play LoRA adapters, **all on llama.cpp / GGUF** — one lane, train where you
serve, so adapters transfer cleanly. Runs on a 16 GB M4 (and any CPU/CUDA/Metal box — same binary).

## Why one lane
LoRA deltas are trained against specific base weights. Train in one quantization and serve in another
and recall degrades (we measured it: a 4-bit-trained adapter served on Q5 kept strong facts, dropped
weak ones). So Constellation **trains and serves in the same GGUF lane**:
- **train** = PEFT (HuggingFace, on the Mac GPU/MPS) → `convert_lora_to_gguf` → a GGUF adapter
- **serve** = `llama-server` with the matching GGUF base + adapter
Same arch both sides ⇒ the adapter applies cleanly. (MLX was dropped — it could 4-bit-train the 8B
locally, but only by creating exactly that cross-quant serving mismatch.)

## The model (100% local — no GPU, no cloud)
- **`8b`** = granite-4.1-8b (Q5) — the serving brain + the teacher that generates self-learning curricula
- **`3b`** = the local **trainable workhorse** — biggest base that PEFT-trains in 16 GB (bf16); capable
  enough for real skills + facts
- **`1b`/`350m`** — edge/tiny adapters
- Everything trains AND serves on the local machine. (8B itself isn't fp16-trainable in 16 GB, so the
  8B is the brain/teacher; adapters are authored on the 3B and below.)

## Commands (`python3.12 kit/constellation.py <cmd>`)
```
ask "<q>" [--base 8b] [--adapter <name>]                 # query the served base, optional adapter
train <name> --data <dir> [--base 350m] [--steps 300]    # PEFT LoRA on an HF base -> GGUF adapter
self-learn <name> --source <file> [--base 8b]            # 8B writes its own Q&A curriculum from a doc,
                                                         #   trains a (350m) adapter on it -> GGUF
serve [--base 8b] [--adapters a,b]                       # llama-server: base + GGUF adapters (hot-swap)
kit                                                      # list your GGUF adapters
```

## What's proven (see ../spike/CONSTELLATION.md)
- **Self-learning**, all-GGUF: 8B reads an unseen doc → writes its own curriculum → PEFT-trains a 350m
  adapter → GGUF → serves → recalls. No MLX.
- **Through the real runtime**: `Nexus.Agent.run` runs on the local 8B (tool-calling + wasm sandbox);
  `Nexus.Llm.complete` reaches a GGUF base+adapter and gets the self-taught fact. See `../run-local-*.sh`.
- **Hot-swap kit**: `llama-server` swaps GGUF adapters live via `POST /lora-adapters`.

## Tiers (same GGUF kit, all local-first)
- **Laptop** — llama-server (CPU) serves any base; PEFT trains adapters on ≤3b. This is the whole product.
- **Edge/browser** — the 350m + adapters via transformers.js/WebGPU (ship in a workbook).
(No GPU/cloud training tier — the point is it runs on the user's own computer.)
