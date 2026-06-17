# Ether

CPU-only, scale-to-zero inference system — the sibling to **Nexus** (the GPU/runtime
compute plane). Where Nexus runs the shared runtime and agents, **Ether** runs small
quantized models *inside* per-tenant CPU microVMs (Fly.io), so inference is isolated,
scale-to-zero, and ideally near-free at the margin when riding a sandbox that already exists.

## Thesis under test
Can a small model on a CPU microVM beat (or get close enough to) OpenRouter's $/token —
or, failing that, win on **isolation + marginal-cost-on-an-already-running-sandbox**?

The standalone $/token battle is mostly lost to batched GPU APIs by physics (no batching
on CPU). Ether's real edge is data-in-sandbox isolation and zero idle cost. The number that
sets the floor is **aggregate tok/s under concurrency** (CPU's substitute for GPU batching),
measured against the memory-bandwidth wall.

## Tracks
- **BitNet track** (`Dockerfile`, `bench.sh`) — Falcon3-10B-1.58bit via `bitnet.cpp`.
  Throughput ceiling of the ternary path. ⚠️ Ternary guts reasoning (see FINETUNE-RESEARCH.md);
  base model only viable for templated/instruction-following authoring, and it can't be cheaply
  fine-tuned (QAT-only, no LoRA-into-ternary).
- **FP-Q4 track** (planned) — QLoRA-fine-tune a small FP model, serve Q4_K_M GGUF via llama.cpp.
  The path we'd actually ship for a Workbooks-specialized model. Model choice: see MODEL-SELECTION.md.

## Files
- `Dockerfile` — bitnet.cpp + Falcon3-10B-1.58bit, baked for a Fly microVM.
- `bench.sh` — CPU facts + single-stream thread sweep + concurrency sweep (aggregate tok/s).
- `cost.py` — measured tok/s → $/M in/out at Fly per-second pricing, vs OpenRouter.
- `FINETUNE-RESEARCH.md` — can/should we fine-tune BitNet for our domain (verdict: not yet).
- `MODEL-SELECTION.md` — best current small model for QLoRA + GGUF-on-CPU (research).
