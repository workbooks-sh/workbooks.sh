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

## The model
- **`8b`** = granite-4.1-8b (Q5) — the brain (serve + generate self-learning curricula)
- **`3b`/`1b`/`350m`** — smaller bases; **350m trains locally** (PEFT fits 16 GB)
- 8B *adapters* train on a **GPU training station** (PEFT QLoRA fits 8B trivially) → GGUF → serve here.

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

## Tiers (same GGUF kit, different surfaces)
- **Laptop** — llama-server (CPU), local PEFT training (≤3b).
- **GPU training station** — PEFT QLoRA trains 8B adapters → GGUF.
- **CPU cluster / cloud** — same GGUF on llama.cpp (vLLM for GPU SOTA), adapters hot-swapped.
- **Edge/browser** — the 350m + adapters via transformers.js/WebGPU.
