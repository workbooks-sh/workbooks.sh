# Ether local-inference spike (desktop, M4/16GB)

Goal: prove the **local two-lane** direction — start with the **router** (two frozen
models behind localhost OpenAI endpoints + an Elixir orchestrator), spec-coupling later.

## Machine
Apple M4, 10 cores, 16GB unified memory, Metal 3, ~105GB free.
Constraint: 16GB shared CPU+GPU. DiffusionGemma (26B MoE, ~13GB Q4, all experts resident)
does NOT fit alongside a 2nd model here → it's a 32GB+ Mac / dGPU-PC tier. On this box the
two-lane test uses *small* models; full DiffGemma waits for bigger hardware.

## Models pulled (weights only, trusted sources — never the fake `gemma-4/Gemma-4-Omni` binary)
- `granite-4.1-3b-Q4_K_M.gguf` — AR/text baseline, fine-tunable via existing ether QLoRA pipeline. (ibm-granite)
- `gemma-4-E4B-it-Q4_K_M.gguf` — small omni (text+image+audio+video), edge fit. (unsloth)
- `gemma-4-12B-it-Q4_K_M.gguf` — full **Unified omni** (encoder-free), single-brain candidate (~7GB Q4). (ggml-org)

## Results
### AR lane — Granite-4.1-3B Q4 — ✅ LIVE
llama-server, Metal (`-ngl 99`), OpenAI `/v1/chat/completions`.
- prompt: one-line `work-card` custom element → `<work-card title="Work Card"></work-card>` (correct)
- decode **43.1 tok/s**, prefill **151.7 tok/s**
- Proves: local GGUF → llama-server → OpenAI bridge == the exact seam `llm.ex` `WB_LLM_BASE_URL` targets.

### Dual-lane concurrency (CPU `ngl0` ∥ GPU Metal) — ✅ DOUBLE-TIME CONFIRMED
Two Granite instances (stand-in for AR-on-CPU + diffusion-on-GPU), same M4:
- SEQUENTIAL: CPU 6.84s + GPU 5.24s → wall **12.7s**
- CONCURRENT: CPU 9.01s ∥ GPU 8.03s → wall **9.35s**  (**1.36×**)
- Lanes overlap on separate compute units (real double-time). Per-lane decode falls under
  load (CPU 29→22, GPU 41→27 tok/s) = shared unified-memory bandwidth — the cost the
  **serial-GPU scheduler** mitigates (one full-GPU diffusion burst at a time leaves bus
  headroom for the parallel CPU pool).

Architecture locked: TWO BRAINS.
- CPU lane = AR model, `ngl 0`, parallel pool (sized to perf cores) — orchestration/tools/fast iterate.
- GPU lane = diffusion model, Metal, **serial 1-slot queue** — full-GPU bursts.
- Scheduler (BEAM): GenServer 1-depth queue for GPU; Task pool for CPU; router by task-type.

### Gemma-4-12B Omni — ✅ ALL MODALITIES CONFIRMED
Text 12.4 tok/s (GPU). Multimodal via `llama-mtmd-cli -mm <mmproj> --jinja`:
- IMAGE: real desktop screenshot → read actual filenames (welcome.work, sandbox.work, kits).
- AUDIO: `say`-generated speech → transcribed "quick brown fox…" exactly (experimental).
- VIDEO: ffmpeg testsrc → described color bars, noted 5-frame sampling.
mmproj: models/mmproj-gemma-4-12B-it-Q8_0.gguf (159MB). Thinking model → use enable_thinking:false.
NOTE: 12B omni + a diffusion model won't co-reside on 16GB; omni is a swap-in / 32GB+ GPU brain.

### Dream-7B diffusion — GPU lane brain (downloading)
diffusion via `llama-diffusion-cli` (Dream/LLaDA; NOT llama-server → needs a wrapper for the lane).

## How to run
    ./serve-ar.sh                       # Granite on :8081 (MODEL/PORT/NGL overridable)
    MODEL=models/gemma-4-12B-it-Q4_K_M.gguf PORT=8082 ./serve-ar.sh   # omni lane
    NGL=0 ./serve-ar.sh                 # force pure-CPU (literal CPU/GPU lane split)

## Built in nexus (gated, OpenRouter stays primary)
- `nexus/lib/ether/lane.ex` — bounded-concurrency lane GenServer (CPU pool / GPU 1-slot serial).
- `nexus/lib/ether.ex` — router (task-type → lane), `run/3`, `children/0`, `tier/0`. OFF unless
  `config :nexus, Nexus.Ether, enabled: true`.
- `nexus/lib/ether/tier.ex` — OS-spec auto-tier. On this M4: `granite-4.1-3b` (CPU, ngl0) +
  `gemma-4-12b` (GPU, Metal). 8GB→CPU-only; 32GB+→AR + DiffusionGemma full two-brain.
- `nexus/lib/llm.ex` — +per-call `base_url` + localhost no-key (default path unchanged).
- Verified: routing, parallel-CPU/serial-GPU (3 jobs → running:1 queued:2), 167 tests green.

## Next
1. Smoke each omni model (text first; then multimodal via --mmproj).
2. Decide Path A (one 12B omni brain) vs Path B (E4B + small diffusion drafter, two-lane).
3. Diffusion GPU lane for real (DiffGemma on a 32GB+ box; small diffusion LM here).
4. Spec-coupling: diffusion drafts a block, AR verifies — plugs into the same lanes.
