# Constellation kit

A Granite base + plug-and-play LoRA adapters, **trained and served locally** on Apple Silicon (MLX).
Validated end-to-end on a 16 GB M4 — including the 8B learning on the GPU while serving on the CPU.

## The model
- **`8b`** = `granite-4.1-8b-mlx-4bit` (the brain; QLoRA-trains locally because the base is 4-bit)
- **`350m`** = the edge/tiny-agent base (ships in a browser/workbook; weak standalone)
- Adapters are MLX LoRA adapters — they **serve natively, no format conversion**.

## Commands (`python3.12 kit/constellation.py <cmd>`)
```
ask "<question>" [--base 8b|350m] [--adapter <name>]      # query base, optionally with an adapter
train <name> --data <dir> [--base 8b] [--iters 300]       # QLoRA-train an adapter on a base
self-learn <name> --source <file> [--base 8b]             # base studies a doc, generates its OWN
                                                          #   Q&A curriculum, trains an adapter on it
kit                                                       # list your adapters
```

## What's proven (see ../spike/CONSTELLATION.md for the full trail)
- **Train an 8B adapter locally** via MLX QLoRA on the 4-bit base (fits 16 GB, ~5.5 GB peak).
- **Self-learning loop**: study → self-generate curriculum → train → know (no human-written facts).
- **Concurrent** GPU-train ‖ CPU-serve the *real 8B* on one 16 GB laptop.
- **Hot-swappable adapter kit** (via llama.cpp `POST /lora-adapters` when serving GGUF).

## Tiers (same kit, different surfaces)
- **Laptop** — this toolkit (MLX, local).
- **CPU cluster (Vultr)** — Granite GGUF on llama.cpp, multi-agent, scale-to-zero; adapters hot-swapped.
- **Edge/browser** — the 350m + adapters via transformers.js/WebGPU (merged-then-shipped).
- **Discrete-GPU server** — separate VRAM/RAM → the continuous self-learning loop runs cleanly.

## Notes / honest limits
- The 350m at 4-bit is a weak base (garbles tokens); use it only for edge demos. The 8B is the real one.
- llama.cpp serving + runtime LoRA hot-swap uses the *GGUF* adapter lane (PEFT→GGUF); MLX adapters
  serve via MLX. Both are validated; pick by tier.
- Dropped: the speculative-diffusion drafter (needs scale/GPU we don't have locally; LoRA-first is the
  better, working product). Archive in `../spike/dflash/_archive_diffusion/`.
