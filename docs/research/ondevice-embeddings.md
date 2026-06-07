# On-device embeddings & visual understanding (June 2026)

**Track:** can a small image/text embedding model on the phone buy Addendum anything — style-consistency scoring, semantic asset selection for the layered art system, RimWorld-ish flavor, pedagogy support? Audited against the locked constraints: local-first, ≤150 MB download (target ≤100), no thermal throttle in 30 min on a 3-year-old mid-range Android, sim determinism, the locked light/chunky-cute design language, Apple 2.5.2, commercial licensing.

**Verdict up front:** ship **zero ML at runtime**. Every image this game shows is a **baked asset**, so both sides of every similarity computation can be computed at **author time** and baked as integer data — embeddings earn their keep in the **content pipeline** (auto-tag suggestion, style-drift CI gate, near-duplicate detection for combination fatigue), not on the device. The strongest 2026 mobile model family (Apple MobileCLIP/MobileCLIP2) is **research-only licensed and cannot ship in a $7.99 game at all**. The best commercially-licensed small model (TinyCLIP, MIT) would cost ~13–30 MB of the bundle and buys nothing the tag system + baked affinity tables don't already do — **unless** the on-device image-generation track ships, in which case a runtime embedder becomes the QC gate for generated images and this doc's Config B is the costed plan.

---

## 1. The model landscape, June 2026

### 1.1 MobileCLIP / MobileCLIP2 (Apple) — technically best, legally dead

The reference family for phone-class image-text embedding. [MobileCLIP](https://github.com/apple/ml-mobileclip) (CVPR 2024) and [MobileCLIP2](https://machinelearning.apple.com/research/mobileclip2) (TMLR, Aug 2025) span 50–150M params at 3–15 ms total latency:

| Model | Image / text params | Latency (iPhone 12 Pro Max, ANE) | IN-1k zero-shot |
|---|---|---|---|
| MobileCLIP-S0 | 11.4M / 42.4M | 1.5 ms + 1.6 ms | 67.8% |
| MobileCLIP2-S0 | 11.4M / 63.4M | 1.5 ms + 3.3 ms | 71.5% |
| MobileCLIP2-S2 | 35.7M / 63.4M | 3.6 ms + 3.3 ms | 77.2% |
| MobileCLIP2-B | 86.3M / 63.4M | 10.4 ms + 3.3 ms | 79.4% |

Core ML artifacts + an iOS demo app exist; community [ONNX exports](https://huggingface.co/plhery/mobileclip2-onnx) put the S0 vision encoder at ~43 MB fp32 (~22 MB fp16, ~11 MB int8).

**The blocker:** code is MIT, but the **weights** are under the [Apple ML Research Model license](https://github.com/apple/ml-mobileclip/blob/main/LICENSE_MODELS) (`apple-amlr`), verified directly from `LICENSE_MODELS`:

> "…exclusively for Research Purposes. … 'Research Purposes' does not include any commercial exploitation, product development or use in any commercial product or service."

It is also **revocable**. Every HF mirror and ONNX conversion inherits this. A premium game is exactly "use in a commercial product." **MobileCLIP and MobileCLIP2 are off the table in any form** — including their Core ML exports. (Self-training a MobileCLIP architecture from scratch on open data is technically permitted — code is MIT — but that's a research project, not a game task.)

### 1.2 Commercially usable alternatives

| Model | License | Total params | On-disk (usable quant) | IN-1k 0-shot | Notes |
|---|---|---|---|---|---|
| [TinyCLIP-ViT-8M/16 + Text-3M](https://huggingface.co/wkcn/TinyCLIP-ViT-8M-16-Text-3M-YFCC15M) (Microsoft, ICCV'23) | **MIT** | 23.4M | **24.3 MB int8**, 47.2 MB fp16 ([ONNX community export](https://huggingface.co/onnx-community/TinyCLIP-ViT-8M-16-Text-3M-YFCC15M-ONNX)) | 41.1% | 2.0 GMACs image side. The smallest shippable two-tower. Weak but real. |
| TinyCLIP-ViT-39M/16 + Text-19M | MIT | ~58M | ~60 MB int8 | 63.5% | Mid option; ~half the remaining bundle headroom. |
| [UForm3 image-text-english-small](https://huggingface.co/unum-cloud/uform3-image-text-english-small) (Unum) | **Apache-2.0** | ViT-S/16 + 4-layer BERT | ~"100 MB incl. runtime" claimed; CoreML+ONNX [exports](https://huggingface.co/unum-cloud/uform-coreml-onnx) | 36.1% | 256-d **Matryoshka** embeddings — truncate to 64-d (64 B/asset int8). |
| [SigLIP 2 B/16](https://github.com/google-research/big_vision/blob/main/big_vision/configs/proj/image_text/README_siglip2.md) (Google, Feb 2025) | Apache-2.0 | ~375M (256k-vocab text tower) | ~375 MB int8 | 78%+ | Quality king of the permissive options; **3.7× the entire bundle target**. No. |
| OpenCLIP ViT-B/32 (LAION-2B) | MIT | ~151M | 85.6 MB q4_0 via clip.cpp | 66.6% | The classic; q4 alone eats most of the headroom. No. |
| [CSD (Contrastive Style Descriptor)](https://huggingface.co/yuxi-liu-wired/CSD) | CC-BY-4.0 | ViT-L/14 base (~300M) | ~600 MB fp16 | n/a (style metric) | The purpose-built **style-similarity** embedder ([paper](https://arxiv.org/abs/2404.01292)). Author-time only, never shippable. |
| EmbeddingGemma-300M (Google, 2025) | Gemma terms (commercial OK) | 308M | <200 MB RAM quantized, <22 ms on EdgeTPU | text-only | No image tower — irrelevant to visual use cases here. |

Nothing released through mid-2026 changes the shape of this: the permissive small end is TinyCLIP-class (41–63% IN-1k), the strong small end is Apple-research-only, and the strong permissive end (SigLIP 2) is desktop-sized.

### 1.3 Latency reality on the floor device

Measured anchors: MobileCLIP-S0's image tower (same ~1–2 GMAC class as TinyCLIP-8M) is **1.5 ms on an iPhone 12 Pro Max ANE** — iPhone is a non-issue. On a 3-year-old mid-range Android (2023 Snapdragon 6-series class, CPU/XNNPACK int8 — NNAPI coverage is too inconsistent to count on), no published per-model number exists for TinyCLIP; extrapolating from its 2.0 GMACs and XNNPACK int8 throughput on that CPU class, **expect ~30–150 ms per 224×224 image, single-shot** (estimate, flagged as such). That is fine for a per-event QC check and completely unusable per-frame — which is fine, because no proposed use is per-frame. One-shot inferences have no thermal-throttle implications; the 30-min perf gate is unaffected by any design in this doc.

Text-side latency is irrelevant: the aspect vocabulary is closed, so **all text embeddings are precomputed at author time** — a runtime text encoder never needs to ship even in Config B (halves the model: vision-only TinyCLIP-8M int8 ≈ **11–14 MB**).

---

## 2. The structural insight that decides everything

**Addendum shows no image at runtime that wasn't baked at author time.** The layered art system (docs/design/brands-and-products.md §4) composes setting × person × product from alpha-cut **baked** layers; the locked content pipeline (docs/02-technical.md §6) bakes everything to data-only Lua tables.

Therefore: for any (image, concept) or (image, image) similarity the game could ever want, **both operands are known at build time**. Embed the whole asset library once in CI, bake the results as integer data, and runtime "visual understanding" becomes a table lookup or an integer dot product in pure Lua. Cost: ~0 MB, ~0 ms, **bit-exact across devices** (integer math in Lua doubles is exact — it can even feed the deterministic sim, which no runtime float inference ever could: ANE vs NNAPI vs XNNPACK outputs differ at the bit level, so runtime model output must stay presentation-side forever).

An on-device model only pays when an image **the build never saw** appears at runtime. In this game there are exactly two candidate sources, both speculative: (1) the on-device image-generation track (separate research doc), (2) user-imported photos ("put your real product in an ad" — not on the design table; drags in App Review content questions). No imagegen ⇒ no runtime embedder. Full stop.

---

## 3. Use-case audit (embeddings vs the tag system we already have)

### (a) Style-consistency scoring — *author-time: yes (CI gate). Runtime: only if imagegen ships, and honestly, weakly.*

- **Author time (recommended, zero runtime cost):** the design language is being locked from generated explorations right now; the real risk is **style drift across authoring batches** (hundreds of layers generated over months through a "style bible" prompt). Add a CI gate in `tools/`: embed every new asset with **CSD** (CC-BY-4.0, ViT-L — fine in a Python pipeline, never shipped) or DINOv2-class features; compute distance to the locked style centroid (seeded from the chosen exploration batch); fail the build past a tuned threshold, exactly like the Layer-1 sign-invariance check. This is the single highest-value item in this doc: it gives the "strict style consistency" ruling a **machine check**.
- **Runtime:** only meaningful as a QC gate on on-device-generated images. Honesty check: the shippable judge (TinyCLIP-8M, 41% IN-1k, content-style entangled like all vanilla CLIPs) is a **weak** style judge; the good judges (CSD, ViT-L class) are ~600 MB and unshippable. If imagegen ships, style control should come primarily from the generator's own conditioning (LoRA/distilled style), with a TinyCLIP gate as a coarse "reject obvious mush" filter, not a style oracle.
- **Tag alternative:** N/A — tags can't score novel images. But absent novel images, there's nothing to score at runtime.

### (b) Semantic asset selection for the layered art system — *tags win, decisively. Embeddings assist at author time only.*

Picking the setting/person/product layer matching a card's aspects ('urgent', 'cozy', 'outdoorsy') is selection over a **closed, hand-curated vocabulary** against a **finite baked library**. That is the textbook case where hand-authored metadata beats learned similarity:

- The aspect taxonomy is **load-bearing pedagogy** (a practitioner reviewer for it is an open DECISIONS item) — selection must be explainable and truthful, not vibes from a 41%-accuracy model.
- Tags are deterministic, free, debuggable, and already exist.
- **Where embeddings genuinely help — in the pipeline:** (1) **auto-tag suggestion**: zero-shot score every layer against the aspect vocabulary with OpenCLIP/SigLIP 2 in Python CI, surface suggestions for human curation — turns tagging hundreds of layers from authoring drudgery into review work. (2) **Baked affinity tables**: instead of binary tags, bake a per-(layer, aspect) **int8 affinity score** (cosine sim, quantized, human-spot-checked). Runtime selection becomes "argmax over a baked integer column" — *continuous*, *deterministic*, richer than binary tags, still zero ML on device. Data cost at 40 aspects × 2,000 layers × 1 byte = **80 KB**.

### (c) RimWorld-ish flavor (auto-describing composed ads, audience-vibe matching) — *grammar + tags win; embeddings add nothing visible.*

RimWorld itself does this with **hand-authored grammar templates over entity tags, no ML**. The composed ad already *is* structured data — every layer carries aspect tags and provenance. A template grammar ("`{person.descriptor}` demos `{product.name}` in `{setting.descriptor}` — `{top_aspect}`-forward") produces deterministic, style-controlled, localizable flavor; it also feeds the strategist-hypothesis voice ("propose, never decide") without any black box. An embedding could at most retrieve the nearest canned flavor line — strictly worse than generating it from the same tags. **Skip.** (Free-text anything is already ruled out for v1 in ad-builder-and-assets.md §4.)

### (d) Pattern-matching pedagogy — *nothing. Flagged honestly, and it's worse than nothing.*

The pedagogy's whole contract is **legible, truthful patterns** (6-case rule table, machine-checked sign invariance, graded pins). Injecting a learned similarity anywhere in that chain replaces an auditable rule with an unexplainable score — it would *undermine* the product's core promise. No embedding use case exists here.

### (e) Bonus find — combination-fatigue near-duplicates (ad-builder open question #5)

The echo penalty's open question — "near-dup tracking is truer to Andromeda but costs a similarity measure" — is answered by **author-time** embeddings for free: visual layers' pairwise cosine similarities are computable in CI and bakeable as a sparse "these layers count as near-duplicates" table (or int8 pair weights). The sim consumes baked integers; determinism intact; the truest version of the mechanic becomes affordable.

---

## 4. Integration (only if Config B is ever triggered)

- **Defold native extension:** extensions are C/C++ with per-platform static libs via `ext.manifest`, built on the cloud builders or the week-one local extender Docker (already planned — large-lib payloads are another reason to have it). Expose `embed.image(buffer) → bytes` to Lua; Defold buffers hand over RGBA pixels directly.
- **Runtime choice, one path:** [clip.cpp](https://github.com/monatis/clip.cpp) (MIT, dependency-free C on ggml, q4–q8 GGUF; proven on Android via [JNI in CLIP-Android](https://github.com/shubham0204/CLIP-Android), Apache-2.0) — static lib ~1–2 MB, same code on both platforms, CPU-only (no driver/NNAPI variance). Caveat: maintenance is thin (last major activity 2024); budget a vendored fork. Alternative: [ONNX Runtime custom minimal build](https://onnxruntime.ai/docs/tutorials/mobile/) — ~3.8–4 MB per ABI (vs 15.5 MB stock), XNNPACK EP, actively maintained.
- **Runtime choice, zero-bundle path:** Core ML on iOS (OS framework, 0 MB, ANE-fast) + LiteRT via Google Play services on Android (runtime not bundled). Cost: two platform code paths and divergent numerics — acceptable because runtime outputs are presentation-only by law (see §2).
- **Apple 2.5.2 / App Review:** model weights are **data**, not code — shipping them, and later delivering updated weights or vector tables via Defold Live Update, is compliant (2.5.2 forbids downloaded *code*; the locked plan already notes Live Update is data-only). Embedding inference raises no review flags; generated *content* questions belong to the imagegen track.
- **Author-time pipeline (the actually recommended work):** a `tools/embed-assets.py` step in the existing content pipeline — open_clip/SigLIP 2 + CSD in Python, outputs int8 affinity tables and near-dup sets into the baked Lua content. Zero device cost, zero new runtime dependencies, CI-enforced.

---

## 5. Size / latency budget

Bundle context: ≤150 MB hard, ≤100 MB target, Balatro mobile 70–93 MB ⇒ realistic ML headroom ≈ 20–40 MB *if it earns its place*.

| Config | What ships | Bundle cost | Runtime cost | Buys |
|---|---|---|---|---|
| **0 — tags only** (today's baseline) | nothing | 0 | 0 | everything in §3b–d via existing tags + grammar |
| **A — author-time embeddings, baked data** ★recommended | int8 affinity tables + near-dup sets | **~0.1–2.5 MB** (80 KB affinities @2k layers/40 aspects; 64-d int8 vectors for 2k assets = 128 KB if raw vectors ever wanted) | integer dot products in pure Lua; ~1M ops ≈ ms-scale even on vanilla Lua 5.1, one-shot | continuous aspect matching, near-dup echo penalty, style-drift CI gate, auto-tag authoring assist — **bit-exact, sim-safe** |
| **B — runtime image embedder** (only with imagegen) | TinyCLIP-8M **vision tower** int8 + ggml/clip.cpp | **~13–16 MB** (11–14 MB model + 1–2 MB lib); full two-tower 26–30 MB (unnecessary — text precomputes) | ~30–150 ms/image mid-range Android CPU (est.); single-digit ms iPhone ANE; one-shot, no thermal impact; ~50–80 MB transient RAM | coarse QC gating of on-device-generated images against precomputed style/aspect anchors. Presentation-only, never sim input |
| **C — quality runtime embedder** | TinyCLIP-39M int8 (~60 MB) or UForm small | 60+ MB | similar, ~2–3× slower | rejected: eats half the headroom for a judge the game doesn't need |

---

## 6. Recommendations

1. **Rule out runtime embedding for v1.** No use case survives the tag-based audit while all displayed images are baked.
2. **Adopt Config A in the content pipeline now** (cheap, compounding): style-drift CI gate (CSD/DINOv2 distance to the locked style centroid — gives the design-language ruling a machine check), CLIP-assisted aspect-tag suggestion with human curation, baked int8 affinity tables for layer selection, and baked near-dup sets that unlock the truest combination-fatigue mechanic (closes ad-builder open question #5 at zero runtime cost).
3. **Hard license rule for the repo:** MobileCLIP/MobileCLIP2 weights (`apple-amlr`) are research-only and revocable — banned from the shipped product *and* from generating any shipped data. Pipeline models must be MIT/Apache/CC-BY (OpenCLIP, SigLIP 2, TinyCLIP, CSD, DINOv2).
4. **Determinism law extension:** runtime ML output (if any ever ships) is presentation-only; anything ML-derived that feeds the sim must be baked integers from CI. Worth a line in docs/02-technical.md §4 if Config B is ever triggered.
5. **Re-open this doc only when** the imagegen track gets a green light (Config B is the costed QC plan: +13–16 MB, vision-only TinyCLIP int8 + clip.cpp), or a permissively-licensed MobileCLIP-class model appears (watch: open reproductions on DataComp; SigLIP-mini-class releases).

---

## Sources

- [apple/ml-mobileclip](https://github.com/apple/ml-mobileclip) — variants, params, iPhone 12 Pro Max latencies; [LICENSE_MODELS](https://github.com/apple/ml-mobileclip/blob/main/LICENSE_MODELS) (AMLR text quoted above, fetched 2026-06-05)
- [MobileCLIP2 — Apple ML Research](https://machinelearning.apple.com/research/mobileclip2) · [MobileCLIP2-S0 on HF](https://huggingface.co/apple/MobileCLIP2-S0) (`apple-amlr`) · [MobileCLIP-S0 on HF](https://huggingface.co/apple/MobileCLIP-S0) (`apple-amlr`) · [plhery/mobileclip2-onnx](https://huggingface.co/plhery/mobileclip2-onnx)
- [TinyCLIP (microsoft/Cream)](https://github.com/microsoft/Cream/tree/main/TinyCLIP) · [wkcn/TinyCLIP-ViT-8M-16-Text-3M-YFCC15M](https://huggingface.co/wkcn/TinyCLIP-ViT-8M-16-Text-3M-YFCC15M) (MIT, 23.4M params, 41.1% IN-1k, 2.0 GMACs) · [ONNX export sizes](https://huggingface.co/onnx-community/TinyCLIP-ViT-8M-16-Text-3M-YFCC15M-ONNX) (24.3 MB int8 / 47.2 MB fp16 / 94.1 MB fp32)
- [SigLIP 2 (big_vision README)](https://github.com/google-research/big_vision/blob/main/big_vision/configs/proj/image_text/README_siglip2.md) · [google/siglip2-base-patch16-224](https://huggingface.co/google/siglip2-base-patch16-224) (Apache-2.0)
- [unum-cloud/uform](https://github.com/unum-cloud/uform) · [uform3-image-text-english-small](https://huggingface.co/unum-cloud/uform3-image-text-english-small) (Apache-2.0, 256-d Matryoshka) · [uform-coreml-onnx](https://huggingface.co/unum-cloud/uform-coreml-onnx)
- [CSD — Measuring Style Similarity in Diffusion Models](https://arxiv.org/abs/2404.01292) · [yuxi-liu-wired/CSD](https://huggingface.co/yuxi-liu-wired/CSD) (CC-BY-4.0, ViT-L base)
- [monatis/clip.cpp](https://github.com/monatis/clip.cpp) (MIT, ggml, 85.6 MB q4_0 ViT-B/32) · [shubham0204/CLIP-Android](https://github.com/shubham0204/CLIP-Android) (Apache-2.0 JNI bindings)
- [ONNX Runtime — Deploy on mobile](https://onnxruntime.ai/docs/tutorials/mobile/) (stock arm64 15.5 MB; custom minimal build 3.8–4 MB; XNNPACK/NNAPI/CoreML EPs)
- [Qualcomm AI Hub — OpenAI CLIP](https://aihub.qualcomm.com/models/openai_clip) (571 MB fp32 — scale anchor for full-size CLIP on mobile)
