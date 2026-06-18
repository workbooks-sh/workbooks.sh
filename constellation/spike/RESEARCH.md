# Ether fusion — heterogeneous compute-diversified speculative decoding

## Thesis (the novel claim)
Speculative decoding, diffusion-drafting (DiffuSpec/DEER), and AR↔diffusion hybrids exist — but
they almost always run drafter + verifier on **one accelerator**, time-slicing it. Apple Silicon
offers something datacenter GPUs don't: **two physically distinct compute units (GPU + CPU/AMX)
sharing one unified-memory pool.** So:

> Run the **diffusion drafter on the GPU** and the **AR verifier on the CPU**, concurrently,
> pipelined, sharing context zero-copy through unified memory — turning the otherwise-idle CPU
> into useful verification while the GPU drafts. Token-parallelism (speculation) **and**
> hardware-parallelism (heterogeneous units) at once, on one consumer chip.

Plus the BEAM-orchestrated **load-adaptive route↔fuse law**: fuse for latency when idle, route for
throughput when busy.

## Setup (Path A — fits 16 GB)
- **Drafter (GPU):** DiffuCoder-7B (masked diffusion, Qwen vocab), our MLX denoise loop. ~4.3 GB.
- **Verifier (CPU):** Gemma-4-12B-it QAT-4bit (AR, multimodal, Gemma vocab). ~7 GB.
- **Bridge:** UAG/SLEM — drafter emits a string; re-tokenize in the verifier's vocab; verify exactly
  there. Drafter vocab irrelevant; **output == Gemma greedy decoding** (correctness guaranteed).
- Verifier is the multimodal omni we'd ship anyway; diffusion is a pure speed accelerator, so its
  quality issues can't corrupt output. Total ~11.3 GB resident → fits 16 GB.

## Foundations proven
- MLX runs CPU‖GPU concurrently: **1.48× overlap** (S0).
- MLX masked-diffusion loop generates correct code (DiffuCoder): valid output, `steps≪gen_len` is
  the speed dial; diffusion gets no KV cache → each step recomputes the full sequence.

## What the experiment measures
1. **Acceptance rate** — how often DiffuCoder's drafts survive re-tokenization + Gemma's agreement.
   THE make-or-break number. Exact-vocab match is the ceiling; UAG sits below it.
2. **tok/s vs baselines** — Gemma AR alone (CPU, GPU) vs fusion (GPU-draft ‖ CPU-verify).
3. Block size K and diffusion steps as the draft-aggression / accept-rate trade.

## Stages
- S0 ✅ heterogeneous MLX concurrency. S1 ✅ MLX diffusion loop. S2/S3 ✅ UAG fusion harness
  (`hetero_fusion_uag.py`). S4 = pipeline draft(N+1)‖verify(N). S5 = benchmark table. S6 = wire into
  Ether route↔fuse.

## Why not the alternatives
- DiffusionGemma (vocab-exact w/ Gemma) is 26B → 32 GB+ only; 2-bit to fit 16 GB = broken. UAG makes
  its vocab-match advantage moot here anyway.
- Gemma native MTP drafter = official ~3× but not diffusion (AR multi-token head) — the honest
  non-diffusion baseline to beat.
- Qwen-twin exact-match pair dropped (user wants the Gemma omni as the shippable verifier).

## The fusion head (trainable centerpiece — the novel contribution)
Sits in the hot loop between draft and verify. Frozen base models; only the head trains.
- **Job (a) accept predictor:** P(verifier accepts token) per position → adaptively size blocks,
  skip verifying doomed drafts.
- **Job (b) learned cross-vocab re-ranker:** UAG/SLEM proposes coarse candidate alignment (free);
  the head re-ranks candidates from (drafter hidden h_d, context state). Output is tiny (scores over
  a few candidates), NOT a 262k softmax — avoids the ~1B-param projection blowup.

**Architecture = Mamba / SSM** (not MLP/Transformer): linear-time, constant per-step state, and its
recurrent state **streams across blocks for free** — matches the block-by-block loop. 1–2 layers,
<<1% of 7B+12B, hours to train, negligible loop latency.

**Training data is free:** every run logs (context_state, h_d, candidate_tokens, verifier_argmax,
accept/reject). Objective = BCE on accept/reject + cross-entropy of re-ranking vs verifier's true
next token (= distilling Gemma's next-token behavior into a cheap conditional head — this is what
lifts accept rate above training-free UAG).

**Positioning:** EAGLE/Medusa-style speculative head, but **cross-model + cross-vocab + Mamba +
diffusion-drafter** — unpublished combination. EAGLE predicts a model's own future tokens; ours
bridges a diffusion drafter to a different-vocab AR verifier via a streaming SSM.

**Go/no-go:** the head only sharpens an existing signal. If the raw DiffuCoder→Gemma UAG accept rate
(first thing we measure) is near zero, there's nothing to learn — that number gates the head build.
Three independent levers overall: verifier LoRA (quality), drafter LoRA (domain-aligned drafts),
fusion head (cross-model accept rate).

## Graph grounding — canonical reconciliation (workbooks moat)
SHARPER FRAMING (not RAG): the drafter and verifier each hold a drifting "view" of the thing; the
workspace graph is the **canonical referent that reorients both toward ground truth.** It ADJUDICATES
drafter↔verifier drift, not just informs. drafter says `work-crd`, verifier leans `work-card`, graph
KNOWS the real node is `work-card` → bias to reality. Division of labor: prose = graph irrelevant;
STRUCTURAL TOKENS (component/element names, imports, refs, file paths, signatures across
WASM↔native↔workbook) = graph authoritative — exactly where models hallucinate.
Mechanisms: (1) head biases accept/re-rank toward graph-attested symbols; (2) grounded/constrained
decoding at identifier positions (grammar-constrained, driven by the LIVE graph) — strongest
reorient-to-canonical lever; (3) RAG = optional soft-context cleanup, not the core.

The workbook substrate is a 3-layer graph: WASM ↔ native-source ↔ workbook(.work/HTML). Nodes =
components / WASM modules / symbols; edges = imports, compiles-to, references. A small GNN encodes it
to a **workspace embedding**.
- **Graph → verifier prompt (RAG):** retrieve relevant graph neighborhood into Gemma's context →
  workspace-aware OUTPUT (the main quality lever; output == verifier).
- **Graph → Mamba head INITIAL STATE (the elegant twist):** seed the SSM recurrent state with the
  workspace embedding; token context then streams updates. Mamba absorbs the graph into state ONCE
  (vs a Transformer head re-attending every step) — so the head anticipates a graph-aware verifier
  cheaply, without re-paying full-graph-in-context per block.
Caveat: the head predicts the verifier, so graph must reach the verifier (RAG) to change output; the
head-state version is the efficiency complement. Moat: generic code models see flat text; we have the
real dependency/compilation/composition graph because the workbook IS that structure (pure dogfood).
Sequencing: later layer — needs base accept rate + GNN encoder + graph-RAG; slots in as head-state
init + verifier-context retrieval without changing the core fusion loop.

## POSITIONING: the worst-case floor
16 GB unified-memory M4 = the HARDEST place to make fusion pay (one RAM pool, one shared memory bus,
and LLM decode is bandwidth-bound → CPU‖GPU overlap is contended, ~1.4× not 2×). That's the point:
prove it efficient HERE and every better-provisioned machine (more RAM, distributed memory, discrete/
multi-GPU with SEPARATE bandwidth) is pure upside. "Runs efficiently on a base M4" >> "runs on a
workstation." The heterogeneous-compute angle is a MODEST bonus on Mac (don't headline it) and gets
LARGE on distributed HW — so Mac is the floor, not the showcase. The substantive, hardware-agnostic
contributions are the algorithm: cross-vocab fusion (UAG) + learned Mamba head + graph grounding.

## PORTABILITY MANDATE (constrains every choice)
NOT Apple-only. Mac-first only to prove the hardest target. Lock the INTERFACES, swap BACKENDS per
platform behind the provider seam (nexus Dock canon; the Ether scheduler is already framework-agnostic
— schedules endpoints, not MLX).
- Portable: fusion logic (draft→verify→accept, head, graph grounding, router); models (DiffuCoder &
  Gemma ship as GGUF + safetensors + MLX); graph schema (CPG/SCIP); featurizers (PyTorch).
- Provider-swappable model runtime: **llama.cpp/GGUF = universal default** (CPU+CUDA+Metal+Win);
  MLX = Mac accelerator provider; vLLM/TensorRT = CUDA. Never pick a runtime that can't port.
- GNN = **PyG** (portable, CUDA/CPU/MPS); mlx-graphs = Mac-only optional accelerator, never the base.
- Mamba = mamba-ssm/Mamba-2 (CUDA-native → portable; Mac uses mamba.py_mlx/MPS port).
- Apple-specific ONLY: unified-memory CPU‖GPU placement = a per-platform optimization (the Mac
  research flavor), NOT the foundation. Same fusion runs GPU-only/multi-GPU elsewhere.

## Off-the-shelf stack (orient our data to these — don't build from scratch)
- **Graph schema:** CPG (Joern spec 1.1) for intra-module AST/CFG/data-flow — its **LLVM-bitcode
  generator ≈ our WASM layer** (no custom WASM graph gen). + **SCIP** (Sourcegraph) for cross-file
  symbol refs; indexers exist: scip-clang (C), rust-analyzer (Rust), scip-typescript (workbook JS).
  → Orient workbook graph data to CPG+SCIP now; inherit tooling/datasets/models.
- **GNN:** PyG for research (Apple MPS) → mlx-graphs (MLX-native, ~10× big graphs, young) for prod.
- **Node featurizer (pretrained, frozen):** GraphCodeBERT (pretrained ON data-flow graphs — most
  aligned w/ reconciliation) or CodeT5+ `codet5p-110m-embedding`.
- **Mamba head:** mamba-ssm/Mamba-2 as a layer, warm-start `cartesia-ai/mamba2-130m-mlx` (pretrained,
  MLX-ready). GOTCHA: official kernels CUDA-only → on Mac use mamba.py_mlx (MLX, trainable) or
  mamba-ssm-macos (MPS); CUDA box for heavy training.
- **Closest prior art:** CGM "Code Graph Model" (2025, arXiv 2505.16901) — graph-into-LLM repo codegen.

## Prior art to cite / build on
UAG (Intel/HF, SLEM cross-tokenizer, training-free); OmniDraft (NeurIPS'25 cross-vocab drafter);
SpecDiff-2 (diffusion drafter alignment); DiffuSpec/DEER (diffusion-draft AR-verify); Diffusion
Forcing & Block-Diffusion/BD3-LM (unified AR+diffusion); UAG-extended MLX-LM on Apple Silicon.
