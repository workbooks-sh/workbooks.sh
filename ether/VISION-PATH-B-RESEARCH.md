# Vision for Granite-4.1 — "Path B" Research (June 2026)

**Question:** How do we give *our* fine-tuned Granite-4.1 (3B/8B dense, Apache-2.0, served Q4/Q5 GGUF on llama.cpp/CPU) **vision** — specifically the narrow ability to look at a rendered screenshot of a workbook/UI it generated and critique it (layout / contrast / binding correctness)? This is a future **Phase-3** of the Ether fine-tune pipeline. We refuse to downgrade our text model to the older `granite-vision-3.3-2b`. Liquid/LFM is out (license).

**Status:** decision-grade research, no code changes. Numbers verified against primary sources where noted; uncertainty flagged inline.

---

## Executive summary

1. **IBM already ships a Granite-4.x vision model** — `ibm-granite/granite-4.0-3b-vision` (Mar 2026) — but its text half is **Granite 4.0 Micro, NOT 4.1**, and it uses a heavy custom head (SigLIP2 + Window-Q-Former + Deepstack, 8 injection points). **There is no `granite-4.1-vision` and no `granite-4.2-vision` as of June 2026.**
2. **Key reversal vs. the stale IBM doc:** llama.cpp **PR #23545 "model: Granite4 Vision" merged Jun 5 2026** — `granite-4.0-3b-vision` *is now GGUF/llama.cpp-runnable* (the IBM/gguf repo's "not currently possible" note is out of date). This makes "adopt IBM's Granite-4 vision" a live option for the first time.
3. **You cannot shortcut by grafting** granite-vision-3.3's trained SigLIP+projector onto 4.1: the SigLIP **encoder** is reusable, but the **projector is not** — it's a learned `1152→2048` map fitted to 3.1-2B's *specific* embedding basis (different vocab/tokenizer, different image-token id, transformer-vs-Mamba-hybrid front end). Re-running stage-1 alignment against 4.1 is mandatory.
4. **Building our own Granite-4.1-VL is feasible but is engineering, not configuration.** llama.cpp's vision path is **per-architecture C++, not encoder-agnostic.** Deviating from a shipped granite-vision tensor/projector contract (e.g. SigLIP2 + a bespoke MLP) means writing/modifying converter + `clip.cpp` graph + projector enum + chat-template code. The de-risked path is to **conform to an IBM granite-vision architecture and only train new weights.**
5. **Corpus minting is the cheap part and we already own the factory:** `runtime/host/evals/components.ex` already does render → headless screenshot → gemini-3 vision-judge. That is a turnkey teacher-student distillation loop. Realistic data: **~50K–300K** image→description pairs for stage-1 alignment (low end OK — narrow UI domain), **~5K–20K** balanced `(image, critique)` pairs for the narrow stage-2 tune (demonstrable from ~1K).
6. **Turnkey trainers (Unsloth / LLaMA-Factory / TRL) will NOT bolt a new encoder onto a bare text LLM** — they only LoRA *existing* VLM checkpoints. Constructing a new VLM needs a builder codebase (**Prismatic-vlms** or **TinyLLaVA-Factory**).
7. **Recommendation: defer vision to a real Phase-3, and when it comes, prefer adopting/aligning to IBM's Granite-4 vision architecture over a from-scratch design.** Ranked: **(a) adopt/track IBM Granite-4.x-vision GGUF ≈ best risk-adjusted**, (b) build our own Granite-4.1-VL by conforming to IBM's contract (medium, ~$1–5k GPU, ~2–6 wks), (c) keep text-only + defer (zero cost, recommended *now*).

---

## 1. VLM construction methods — proven recipes

### Architecture (canonical, unchanged 2023→2026)
`frozen vision encoder → projector (MLP) → text LLM`. The projector maps vision patch features into the LLM's token-embedding space; projected vectors are spliced in as "visual tokens." LLaVA-1.5's one durable upgrade was the projector going from a single linear layer to a **2-layer MLP + GELU**.

### The standard 2-stage recipe (LLaVA-1.5)

| | Stage 1 — projector alignment | Stage 2 — visual instruction tune |
|---|---|---|
| **Data** | ~558K image–caption pairs (LAION-CC-SBU subset) | 665K instruction mix (VQAv2/GQA/OCR-VQA/A-OKVQA/RefCOCO/VG + GPT-4-gen conversations) |
| **Frozen** | vision encoder **+ LLM** | vision encoder only |
| **Trained** | **projector MLP only** | **projector + LLM** (full-FT; LoRA variant also released) |
| **Time (13B, 8×A100-80G)** | ~5.5 h | ~20 h |

LLaVA-1.5-13B total ≈ **~25 GPU-h on an 8×A100 node** ("~1 day," 1.2M public samples); 7B ≈ half. Encoder = CLIP ViT-L/14@336 → 576 tokens.

**Rented-cost translation (June 2026, ~$1.5–2.5/A100-h, ~$2–3/H100-h):** a full LLaVA-1.5-7B reproduction ≈ **100–130 A100-h → ~$200–350** (H100 ~$150–300). A *narrow projector-only* run (see §3) is far cheaper — **<20 GPU-h / <$50**.

### 2024–2026 follow-ups that matter
- **Prismatic VLMs** (Karamcheti et al., arXiv:2402.07865) — the "what matters" ablation across ~50 VLMs. Two load-bearing findings: **single-stage training** (train projector+LLM jointly, skip the projector-only pretrain) **matches two-stage at lower compute**; **fused DINOv2+SigLIP** beats CLIP-only. They fully fine-tune the LLM and find base ≈ instruct LLMs as VLM bases.
- **Cambrian-1**, **LLaVA-OneVision** — same skeleton, vision-centric / multi-modal scaling; confirm SigLIP-class encoders as the modern default.

### Encoders in 2025–2026

| Encoder | Params | Res | Tokens | Embed dim | Note |
|---|---|---|---|---|---|
| CLIP ViT-L/14@336 | 304M | 336 | 576 | 1024 | LLaVA-1.5 default; legacy |
| **SigLIP2 so400m/14@384** | 400M | 384 | **729** | **1152** | **current default** |
| **SigLIP2 so400m NaFlex** | 400M | variable | variable | 1152 | native aspect ratio — best for **OCR / UI / docs** |

**Default in 2026 = SigLIP2 (so400m).** For *our* use case (UI screenshots are OCR/layout-heavy), the **NaFlex variable-resolution** variant is the standout — it buys far more than a bigger LLM would. (Caveat: NaFlex/SigLIP2 graph support in llama.cpp is the load-bearing uncertainty — see §3.)

### Projector-only vs +LoRA for a NARROW task (UI critique)
- Stage-1 projector-only alignment genuinely teaches a frozen LLM to "see" — it's a real capability, not a no-op. For a *narrow, templated* output ("list layout/contrast/binding issues") over a strong SigLIP2 encoder that already encodes the visual structure, **a well-trained projector can carry surprisingly far.**
- **But** ablations consistently show image-involved *reasoning* improves when the LLM is also adapted (projector+LoRA > projector-only). The modality shift from text→vision-language is larger than LoRA's low-rank capacity comfortably covers, and a fully-frozen LLM never adapts its reasoning to visual tokens.
- **Smallest viable recipe:** SigLIP2-so400m(-NaFlex), frozen + 2-layer MLP projector, **train projector-only first** (~few-K–50K UI→critique pairs, **<20 GPU-h / <$50**). If format/reasoning is weak, add **LLM LoRA rank 8–16** in a second pass on the same data.
- **Uncertainty:** no paper isolates "frozen-LLM, projector-only, single UI-critique skill." The "projector-only first, add LoRA if needed" plan is an informed extrapolation — the only way to know is to run the cheap projector-only experiment.

---

## 2. Does IBM already provide a Granite-4.x vision we could use/convert?

**`ibm-granite/granite-4.0-3b-vision`** (released Mar 2026):
- **Base LLM:** Granite **4.0 Micro (3B)** + LoRA (rank 256) across attention/MLP — i.e. **4.0-quality text, NOT 4.1.**
- **Encoder:** SigLIP2 (`google/siglip2-so400m-patch16-384`).
- **Projector:** **Window Q-Former** (4× compression) **+ a Deepstack variant** — features injected additively into LLM hidden states at **8 layers**. Materially more complex than the 3.x plain-MLP connector.
- **Tiling:** 384×384 tiles + a downscaled base view, each tile encoded independently.
- **Trained for:** chart/table/key-value extraction from documents (document-AI lineage).

**There is no `granite-4.1-vision` and no `granite-4.2-vision`.** The `ibm-granite` org lists only `granite-4.0-3b-vision` as multimodal; 4.1 is text/speech/guardian only; no 4.2 models exist. *(Do not be misled by `granite-speech-4.1-2b-nar`'s stray "image feature extraction" HF tag — it's an ASR model.)*

**Predecessor line (the simpler, long-proven one):** `granite-vision-3.2-2b` (Feb 2025) and `granite-vision-3.3-2b` (Jun 2025) — base **Granite-3.1-2B-instruct** (128k), SigLIP2 encoder, **two-layer MLP + GELU** projector (`LlavaNextForConditionalGeneration`), trained for visual document understanding. Hidden dim **2048**, vision dim **1152**, `image_token_index 49155`, vocab 49152.

**Implication:** "use IBM's vision off the shelf" means either (a) `granite-4.0-3b-vision` = **4.0-quality text** (a downgrade from our 4.1 text, though milder than dropping to 3.x), or (b) `granite-vision-3.3` = **3.1-quality text** (a bigger downgrade, the one we explicitly refuse). Neither *is* our 4.1 text model with vision — that remains a build.

---

## 3. GGUF conversion feasibility — the key risk

### How llama.cpp serves VLMs (June 2026)
Multimodal runs through **`libmtmd`** (replacing the old `llava.cpp`), via **`llama-mtmd-cli`** and **`llama-server`**. The vision encoder + projector are converted to a **separate `mmproj-*.gguf`**, loaded alongside the LLM GGUF (`--mmproj`). Conversion = run `convert_hf_to_gguf.py` twice (once normal, once `--mmproj`). Confirmed-supported families include Gemma 3/4, Qwen2/2.5/3-VL, Pixtral, InternVL, MiniCPM-V, Llama-4-Scout, SmolVLM, **and IBM Granite Vision**.

### Is the path encoder-agnostic? **NO — it is per-architecture C++.**
This is the load-bearing finding. In `tools/mtmd/clip.cpp`:
- A generic `build_vit()` exists, but its own comment says *"if your model has specific features, you should probably duplicate this function"* — non-vanilla encoders need a new hand-written graph.
- Dedicated graph builders exist per arch: `clip_graph_siglip`, `_pixtral`, `_qwen2vl`, `_minicpmv`, `_internvl`, `_llama4`, `_gemma4v`, …
- The projector is a **closed enum** `PROJECTOR_TYPE_*` with explicit C++ per type: `MLP`, `MLP_NORM`, `LDP`, `RESAMPLER/MINICPMV`, `QWEN2VL/25VL/3VL`, `INTERNVL`, `GEMMA3/4V`, … **and `GRANITE4_VISION`**.
- Encoder selection is **metadata-driven** (`proj_type` / `--clip-model-is-siglip` → a `clip.projector_type` GGUF key) and dispatched to the matching graph. Convert a model whose `proj_type` the C++ doesn't know → **`unknown projector type` load failure.**

**So an arbitrary/novel encoder+projector will NOT "just convert."** Both a converter branch *and* the clip.cpp graph + projector enum must already exist for your exact design.

### Does the converter support granite-vision specifically? **YES — incl. Granite-4.**
- `docs/multimodal/granitevision.md` ships in-tree (the 3.x SigLIP recipe: `llava_surgery_v2.py` → `convert_image_encoder_to_gguf.py --clip-model-is-siglip …` → extract `GraniteForCausalLM` LLM → `convert_hf_to_gguf.py` → `llama-mtmd-cli`).
- **PR #23545 "model: Granite4 Vision" — MERGED Jun 5 2026** — added `PROJECTOR_TYPE_GRANITE4_VISION`, the `clip.vision.feature_layer` / `image_grid_pinpoints` keys, and **q-former projector tensors** (`V_QF_PROJ_QUERY` …). Granite-4 vision is wired in C++.
- ⚠️ **The IBM/gguf `docs/convert-vision-models.md` is STALE:** it still says Granite-4 (`Granite4VisionForConditionalGeneration`) is "not currently possible." That predates PR #23545. **Verify against current llama.cpp master, not the IBM doc.** (IBM's doc remains correct for the **3.x** recipe.)

### What breaks if we hand-build Granite-4.1 + SigLIP2 + custom MLP projector?

| Component | Status | Risk |
|---|---|---|
| **(a) LLM half — Granite-4.1 dense text** | **Supported.** `granite` / `granitemoe` / `granitehybrid` arches all in gguf-py; Granite-4.0 GGUFs ship today. | **Low.** Confirm exact arch string: plain dense → `granite`; Mamba-2 hybrid → `granitehybrid` (supported, "throughput optimization ongoing"). |
| **(b) Encoder — SigLIP2** | **Partial / uncertain.** `clip_graph_siglip` exists but is wired for **SigLIP-1**-shaped configs. SigLIP2 (pos-embed/attn-pool/NaFlex tiling differences) **not confirmed** drop-in. | **HIGH / UNVERIFIED.** May need a new/adapted `clip_graph_*`. The single biggest unknown — must test against master. |
| **(c) Projector — custom 2-layer MLP** | `PROJECTOR_TYPE_MLP`/`MLP_NORM` exist; plain-MLP *type* supported. | **Medium.** Converter only emits mmproj if it recognizes the HF `architectures` and maps your tensor names to expected keys. Bespoke tensor names → need a converter branch. Granite-4 vision's graph expects **q-former**, not vanilla MLP — deviating throws you onto the generic MLP path you must wire yourself. |
| **(d) Tokenizer / image-token insertion** | Per-model `<image>` expansion + `image_grid_pinpoints` + jinja template baked into mtmd. | **Medium.** Image-token count = tiling × projector downsample; mismatch → garbage/assert. Must match the registered template + grid math. |

**Realistic path:** match an IBM granite-vision encoder+projector contract and only train new weights. The **cheapest confirmed-working "own weights, reuse runtime"** route is to train the projector against IBM's **exact 3.x design** (SigLIP-1 tower + LlavaNext/MLP layout) → in-tree recipe accepts it with **zero C++**. A genuinely novel combo (SigLIP2 + bespoke MLP) = **real upstream-style C++/Python work** (converter branch + possibly a SigLIP2 graph + projector entry + template/token math). Feasible (the repo adds models weekly) but engineering, not config — and SigLIP2-graph support is the load-bearing risk to verify first.

---

## 4. Can we reuse granite-vision-3.3's encoder+projector on Granite-4.1?

**Verdict: NO (projector). The SigLIP encoder IS reusable; the projector is NOT.** You must re-run at least stage-1 projector alignment against the 4.1 target. Confidence: high.

**Why the projector doesn't transfer (three independent reasons):**

1. **Model-specific embedding basis (decisive).** Granite Vision's projector is a learned `1152→2048` 2-layer MLP whose outputs are *fitted to land inside Granite-3.1-2B's specific input-embedding manifold* (paper: make visual tokens "the same dimensionality as the word embedding space in the language model"). Every LLM learns its own embedding geometry/basis/scale; a vector meaning "blue button" in 3.1's space is an arbitrary direction in 4.x's space. LLaVA maintainers warn explicitly: *"use the same base LLM and vision encoder used for pretraining the projector, otherwise performance will be very poor"* (LLaVA #474 / MODEL_ZOO).

2. **3.1-2B and 4.x are different models even where dims coincide.** Verified from configs:

   | | granite-3.1-2b (vision base) | granite-4.0-h-micro (3B) |
   |---|---|---|
   | hidden_size | **2048** | **2048** |
   | model_type | `granite` (transformer) | `granitemoehybrid` (Mamba-2/attn hybrid, NoPE) |
   | vocab_size | **49152** | **100352** |

   The hidden dim *coincidentally* matches at 2048 for the Micro tier (do **not** assume it holds for 8B/Small — verify per target). But **different vocab → different embedding table + tokenizer + image-placeholder token id** (the projector's outputs were aligned to slot 49155, which doesn't exist/means something else in 4.x), and **different architecture** (transformer vs Mamba-2 hybrid, no RoPE) changes the residual-stream statistics the front end expects.

3. **If dims had differed**, the `→2048` output layer wouldn't even load — the trivial hard-fail case.

**What IS reusable / the correct procedure:** keep the **frozen SigLIP2 encoder weights** (LLM-agnostic; real savings — the expensive tower is kept). **Retrain the projector** via stage-1 alignment against Granite-4.1 (freeze encoder + LLM, train MLP on image→caption so outputs land in 4.1's space). Define a new image-placeholder token in the 4.1 tokenizer and wire `image_token_index`. *Uncertainty:* no official 4.1 VLM card exists; the 2048 dim-match is verified only for the 3B Micro tier.

---

## 5. Manufacturing the training corpus from our own render pipeline

**We already own the factory.** `runtime/host/evals/components.ex` does exactly the teacher loop: agent emits a component → `mount_and_shoot/2` mounts it headless and screenshots **light + dark** (`Workbooks.Browse.Headless`) → `vision_judge/3` attaches the frames to a gemini-class vision judge that scores layout/contrast/render-fidelity. That is render → screenshot → structured critique = a complete teacher-student distillation source for the single narrow skill we want.

**Minting loop:**
1. Take real generated workbooks/UIs as **GOOD** variants.
2. **Mutate to BROKEN** variants — one/few defects each, spanning a **defect taxonomy** so each class is learned: *contrast/color* (low-contrast text, clashing/off-brand palette), *layout* (overflow/clip, the known SVG `flex:0` width-collapse, overlap, broken breakpoint), *binding* (empty/wrong binding, `{{var}}` placeholder leakage, label↔value mismatch, stale/dup rows).
3. **Render** each → screenshot (match production viewport/DPI/theme, incl. the Dark-Reader-lock dark-mode setting).
4. **Label** with the gemini-3 teacher's critique. For broken ones, optionally feed the known injected defect as a weak-supervision hint to cut label noise; keep some blind-labeled to avoid leaking the pattern.
5. Store `(image, critique)` with a **fixed JSON schema** (`{defect_class, location, severity, fix}`) so the student learns a parseable target.

**How many pairs (order of magnitude):**
- Anchor: LLaVA-1.5 general-purpose = **558K align / 665K instruct**. Narrow single-domain fine-tunes run *far* smaller (Med-VQA ~14K; documented domain LoRA SFTs from ~400 samples).
- **Stage-1 (projector alignment to 4.1)** — the part you cannot skip (§4): aim **~50K–300K** image→description pairs; the narrow UI domain lets you sit toward the low end (~50K–100K), but below ~50K risks a weak connector. *(Least-certain number; scale this first if alignment underperforms.)*
- **Stage-2 (narrow critique LoRA on projector+LLM):** **~5K–20K** defect-balanced `(image, critique)` pairs; usable first cut demonstrable at **~1K–3K**.
- **Smoke test:** ~1K stage-2 pairs on top of any stage-1 connector — proves the loop, not shippable.

**Pitfalls (dominate at small scale):** teacher hallucination (label-noise ceiling — audit a sample, feed injected-defect ground truth, never let student exceed un-audited teacher); defect-class diversity (only contrast bugs → only learns contrast — stratify + report per-class); good/broken balance (~40–50% good, plus "good-but-unusual" negatives so *unusual* ≠ *broken*); dedup (perceptual-hash) + **split by source** (no source in both train/eval); render-distribution match to production.

---

## 6. Tooling — what trains LLaVA-style VLMs in 2026

**The trap: turnkey fine-tuners do NOT let you bolt a new encoder onto a bare text LLM.**
- **LLaMA-Factory** — fine-tunes **existing known VLM checkpoints only** (LLaVA-1.5/NeXT, Qwen2/2.5/3-VL, PaliGemma, Llama-3.2-Vision, InternVL, MiniCPM-V, GLM-4V). No `text-LLM + encoder` assembly. Granite-4.1 text is not a supported new-VLM base.
- **Unsloth** — same: targets pre-integrated VLM architectures; great for cheap LoRA on an *existing* VLM, can't graft an encoder onto a text model.
- **TRL** — SFT/DPO trainers usable with VLMs, but assumes a model already multimodal in `transformers`. A trainer, not an architecture assembler.

**To construct a NEW VLM you need a builder codebase:**
- **Prismatic-vlms** (TRI-ML) — most principled; clean encoder/LLM/projector swapping, single-stage option. Best for "arbitrary text LLM + arbitrary encoder."
- **TinyLLaVA-Factory** — explicitly modular (LLM / vision-tower / connector swappable; CLIP/SigLIP/DINOv2). Best fit at **3B scale** for a small team.
- Original **LLaVA** repo — reference, more manual. **ms-swift** — broader than LLaMA-Factory but still checkpoint-centric.
- Public analog: **DinoV2-SigLIP-Phi3-LoRA-VLM** (~3.8B, bolts DINOv2+SigLIP onto Phi-3 with LoRA) — closest to our plan.

**Recommended for a small team:** build the VLM with **TinyLLaVA-Factory or Prismatic** (Granite-4.1 + SigLIP-class encoder + 2-layer MLP), single-stage, projector-only first then optional LoRA; reserve **LLaMA-Factory/Unsloth** only for *post-hoc* LoRA on the resulting VLM. A narrow-task prototype is a single rented H100 for well under a day — **~$50–300**.

> **Tension to resolve before building (important):** §3 says the *de-risked llama.cpp serving* path is to **conform to IBM's exact granite-vision tensor/projector contract** (so the existing C++ graph + converter accept it). But §6's flexible builders (Prismatic/TinyLLaVA) make it *easy* to deviate (different encoder/projector tensor names) — which then **breaks GGUF conversion**. So: build with TinyLLaVA/Prismatic, **but pin the encoder + projector design to match a llama.cpp-supported granite-vision architecture** (3.x SigLIP-1 + MLP = zero-C++ path; Granite-4 q-former = also supported post-PR-#23545). Do not let training-side convenience pick an architecture that the serving side can't convert.

---

## 7. Bottom line — ranked recommendation, effort/cost, biggest risk

### (a) Adopt / track IBM Granite-4.x-vision GGUF — **best risk-adjusted; do this first**
- **What:** use `granite-4.0-3b-vision` directly (GGUF now possible post-PR-#23545) as the *vision-critique* model, separate from our 4.1 text coder; or wait for an eventual `granite-4.1-vision`.
- **Effort:** **days.** Smoke-test the GGUF + mmproj on our pinned llama.cpp build; wire it as a second model behind the existing judge seam.
- **Cost:** ~$0 training (inference only). Two resident models (4.1-text coder + 4.0-vision critic) = more RAM, fine for a CPU box that already scales to zero.
- **Biggest risk:** the **vision critic's text brain is 4.0-Micro, not 4.1** (acceptable for a *critique* head — it doesn't author code) **and** GGUF support is new (Jun 5 2026 PR) — **verify the exact GGUF actually loads + runs on our pinned llama.cpp** before relying on it (this is the recurring Granite-on-llama.cpp pinning risk). Secondary: no `granite-4.1-vision` exists, so "our 4.1 text *with* vision" is not achievable this way.

### (b) Build our own Granite-4.1-VL (conform to IBM's contract, train new weights)
- **What:** Granite-4.1 LLM + SigLIP(2) encoder + projector, trained on our minted UI-critique corpus. Pin the encoder/projector design to a **llama.cpp-supported granite-vision architecture** so it converts.
- **Effort:** **~2–6 calendar weeks** for a small team. Stage-1 projector align + stage-2 narrow LoRA = **single-digit to low-tens of GPU-days** (projector-only prototype <20 GPU-h; full two-stage on 50K–300K align + 5K–20K instruct ≈ **~$1k–5k** rented H100). Plus a wildcard C++ task **if** we deviate from a shipped contract (esp. SigLIP2 graph).
- **Biggest risk:** **GGUF conversion of a non-conforming design** — llama.cpp is per-architecture C++; SigLIP2-graph support is **unverified** and a bespoke projector needs a converter branch. If we conform to the 3.x SigLIP-1 + MLP contract this risk collapses (zero C++) but we inherit that contract's older encoder. Secondary: stage-1 alignment underperforming (the least-certain data number).

### (c) Keep text-only + defer vision — **recommended NOW**
- **What:** ship Ether's Granite-4.1 text coder; keep the gemini-3 vision-judge (already in `components.ex`) as the *external* proofing critic. Revisit vision when (b)'s prerequisites are cheap or when `granite-4.1-vision` ships.
- **Effort/cost:** **$0.**
- **Biggest risk:** the proofing loop stays dependent on a hosted frontier model (gemini-3) rather than our own CPU-served model — i.e. the "self-proofing, fully local" goal is deferred, not lost.

### Recommendation
**Now:** (c) — text-only ships; the gemini-3 judge already covers proofing. **Phase-3 trigger:** start with (a) — adopt `granite-4.0-3b-vision` GGUF as a local vision critic (its 4.0-Micro brain is fine for *critique*, and it removes the hosted-model dependency cheaply). Only escalate to (b) — building a true Granite-4.1-VL — if (a)'s critique quality is insufficient *and* a `granite-4.1-vision` still hasn't shipped; and if so, **conform to a llama.cpp-supported granite-vision architecture** and treat SigLIP2-graph support as a budgeted spike to verify before committing.

---

## Sources

**VLM construction / encoders / tooling**
- LLaVA-1.5 — arXiv:2310.03744 · https://github.com/haotian-liu/LLaVA · https://static.hliu.cc/files/llava/improved_llava.pdf · https://learnopencv.com/llava-training-a-visual-assistant/
- Prismatic VLMs — arXiv:2402.07865 · https://github.com/TRI-ML/prismatic-vlms
- SigLIP2 — https://huggingface.co/blog/siglip2 · https://arxiv.org/pdf/2502.14786
- Projector vs LoRA — https://arxiv.org/html/2503.07603v1
- LLaMA-Factory — https://github.com/hiyouga/LlamaFactory · Unsloth vision — https://docs.unsloth.ai/basics/vision-fine-tuning · TinyLLaVA-Factory — arXiv:2405.11788 · DinoV2-SigLIP-Phi3-LoRA-VLM — https://github.com/NMS05/DinoV2-SigLIP-Phi3-LoRA-VLM

**IBM Granite vision models**
- https://huggingface.co/ibm-granite/granite-4.0-3b-vision · /discussions/5 (when-gguf)
- https://huggingface.co/ibm-granite/granite-vision-3.3-2b · /blob/main/config.json · granite-vision-3.2-2b
- https://huggingface.co/ibm-granite (org listing) · granite-vision-3.3-2b-GGUF
- https://huggingface.co/ibm-granite/granite-3.1-2b-base/blob/main/config.json · granite-4.0-h-micro/blob/main/config.json
- Granite Vision paper — https://arxiv.org/html/2502.09927v1
- LLaVA projector-must-match-base — https://github.com/haotian-liu/LLaVA/issues/474

**GGUF / llama.cpp**
- multimodal doc — https://github.com/ggml-org/llama.cpp/blob/master/docs/multimodal.md · mtmd README — /tools/mtmd/README.md
- clip.cpp (graphs + projector enums) — https://raw.githubusercontent.com/ggml-org/llama.cpp/master/tools/mtmd/clip.cpp
- gguf constants (GRANITE arches, q-former tensors) — https://raw.githubusercontent.com/ggml-org/llama.cpp/master/gguf-py/gguf/constants.py
- granite-vision conversion doc — https://github.com/ggml-org/llama.cpp/blob/master/docs/multimodal/granitevision.md
- **PR #23545 "model: Granite4 Vision" (merged Jun 5 2026)** — https://github.com/ggml-org/llama.cpp/pulls?q=is%3Apr+granite+vision
- IBM/gguf repo (convert-vision-models.md — STALE re Granite-4) — https://github.com/IBM/gguf/blob/main/docs/convert-vision-models.md
- Granite-4.0 hybrid Mamba-2 arch — https://www.ibm.com/new/announcements/ibm-granite-4-0-hyper-efficient-high-performance-hybrid-models

**Corpus / narrow-domain data scales**
- LLaVA-1.5 data (558K/665K) — https://github.com/haotian-liu/LLaVA/blob/main/docs/Data.md
- Med-VQA / small-domain SFT — https://arxiv.org/pdf/2403.02469 · https://arxiv.org/pdf/2404.16385 · AgMMU https://arxiv.org/pdf/2504.10568
- Our in-repo teacher loop — `runtime/host/evals/components.ex` (`mount_and_shoot/2`, `vision_judge/3`)

## Confidence / caveats
- **Confirmed:** llama.cpp per-architecture (non-agnostic) vision; granite-vision 3.x + 4.0 conversion supported (PR #23545); projector non-transferability across base LLMs; IBM/gguf doc stale on Granite-4; no `granite-4.1/4.2-vision` exists; LLaMA-Factory/Unsloth can't assemble a new VLM.
- **Inferred / must verify before committing:** **SigLIP2 graph support in current clip.cpp** (biggest unknown for a deviating build); stage-1 alignment data sizing (least-certain number); exact 4.1-tier hidden dims (2048 verified only for 3B Micro); exact GGUF load on *our pinned* llama.cpp (recurring Granite pinning risk — smoke-test always).
