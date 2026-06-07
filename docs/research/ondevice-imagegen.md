# On-device image generation reality check (June 2026)

**Question:** could runtime, on-device image generation make Addendum roguelike-dynamic — brand logos, products, ad visuals generated per run, RimWorld-style brand simulation, maybe an on-device embedding model for visual understanding?

**Verdict up front: NO for v1, and almost certainly no for the core loop ever, on these constraints.** The blockers are not speculative — they are arithmetic: the smallest shippable diffusion model is ~6–10× the *entire* app download budget; the 3-year-old mid-range Android perf floor fails by an order of magnitude; runtime generation cannot hold the locked single-style design language; and the one zero-cost path (Apple ImageCreator) is iPhone-15-Pro-and-newer only, Apple-styled, and has no Android counterpart. The already-proposed layered art system delivers the same combinatorial dynamism at zero runtime cost and full determinism. There is one narrow, honest post-v1 slot for ML: an optional cosmetic "vanity" tier — and even that has style-mush risk.

Everything below is sourced from live research, June 2026. Extrapolations are labeled.

---

## 1. Core ML / ml-stable-diffusion: state of the art on iPhone

### What actually runs

Apple's [ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion) remains the reference pipeline (Swift + Core ML, Neural Engine). Last release **v1.1.1, May 2024** — the repo is essentially in maintenance mode; it supports SD 1.5/2.1, SDXL, SD3 conversion, mixed-bit palettization (1/2/4/6/8-bit, JIT-decompressed on iOS 17+), and W8A8 activation quantization for A17 Pro/M4-class chips. **No runtime LoRA/adapter support.**

### Measured latency (Apple's own benchmarks, SD 2.1-base, 512×512, 20 steps, 6-bit palettized, NE)

| Device | End-to-end | iter/s |
|---|---|---|
| iPhone 12 mini | 18.5 s | 1.44 |
| iPhone 12 Pro Max | 15.4 s | 1.45 |
| iPhone 13 | 10.8 s | 2.53 |
| iPhone 14 | 8.6 s | 2.57 |
| iPhone 14 Pro Max | 7.9 s | 2.69 |

SDXL-base (768×768) for scale: iPhone 13 Pro Max 86 s, iPhone 14 Pro Max 77 s, **iPhone 15 Pro Max 31 s**. SDXL-class is out of the question on anything older.

**Turbo/Lightning-class extrapolation (labeled):** sd-turbo and Lightning distills cut steps from 20 to 1–4, so the UNet cost drops ~5–20×: roughly **1.5–4 s on iPhone 14-class, ~1–2 s on 15 Pro/16/17-class** for 512×512. Draw Things' Metal FlashAttention work (43–120% speedups across SD architectures, iPhone 12+) supports the order of magnitude. No vendor publishes official iPhone 16/17 diffusion benchmarks; Apple's table stops at the 15 Pro Max.

### RAM

Apple warns generation "may exceed 2 GB peak memory"; the mitigation (`reduceMemory`, `.cpuAndNeuralEngine`) **adds up to 2 s latency** from model load/unload. iPhone 12 (4 GB RAM, ~2–2.5 GB jetsam ceiling) is the supported floor (A14 minimum) and is borderline in practice. A Defold game holding atlases + audio + the sim would be co-resident with a ~1.5–2 GB inference peak — expect jetsam kills on 4 GB devices.

### Thermal

The [Draw Things wiki](https://wiki.drawthings.ai/wiki/How_Powerful_Is_My_Device) is blunt: *"thermals are an issue on iPhones and iPads — these devices aren't meant to generate images for long, and performance will quickly dip if they get too hot."* Repeated generation (the roguelike use case: N brands × M products × ad visuals per run) is exactly the sustained-load pattern that throttles. Addendum's perf gate — **no visible thermal throttle in a 30-minute session** — and repeated diffusion are mutually exclusive on phone-class silicon in 2026.

---

## 2. Licensing for a paid commercial game

The good news: licensing is *not* the blocker people assume — several fast models are shippable. The matrix:

| Model | License | Shippable in a $7.99 game? |
|---|---|---|
| **SD 1.5** | [CreativeML OpenRAIL-M](https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-v1-5) | **Yes** — commercial use permitted; must pass Attachment-A use restrictions downstream (EULA clause). Provenance wobble: the canonical `runwayml/` repo was taken down Aug 2024; the model now lives under the `stable-diffusion-v1-5/` org with license intact. |
| **sd-turbo** (SD 2.1 distill, 1–4 step, 512px) | [Stability AI Community License](https://huggingface.co/stabilityai/sd-turbo) | **Yes, conditionally** — free commercial use **under $1 M annual revenue**, requires "Powered by Stability AI" attribution; license is *revocable*; >$1 M needs an enterprise deal. |
| **SDXL-Turbo** | Same [Community License](https://huggingface.co/stabilityai/sdxl-turbo/blob/main/LICENSE.md) (relicensed; launch license was research-only) | Same conditional yes — but SDXL-class doesn't fit phones anyway. |
| **SDXL-Lightning** (ByteDance) | [OpenRAIL++-M](https://huggingface.co/ByteDance/SDXL-Lightning/blob/main/LICENSE.md) | Yes (true open commercial), but SDXL-sized. |
| **SDXS** (one-step, real-time) | [OpenRAIL++ weights; training code closed, project dormant](https://github.com/IDKiro/sdxs) | Technically yes; unmaintained research artifact — risky foundation. |
| **FLUX.1-schnell** | Apache 2.0 | License-clean but 12 B params (~6–7 GB quantized) — physically absurd on phones. |
| **Sana** (NVIDIA, efficient) | Code Apache 2.0; image-model **weights CC-BY-NC-SA** | **No** — non-commercial weights. |
| **MobileDiffusion / SnapFusion** (Google/Snap research) | Never released | No. |

Practical reading: **sd-turbo is the realistic candidate** (right size class, 1–4 steps, commercially usable at indie revenue) — with a revocable license and a revenue cliff at $1 M, which a Balatro-like hit would blow through. SD 1.5 + a step-distilled fine-tune under OpenRAIL-M is the only path with no revenue cap.

---

## 3. Apple Image Playground / ImageCreator — the zero-size path

The [ImageCreator API](https://developer.apple.com/documentation/ImagePlayground/ImageCreator) (iOS 18.4+) lets apps programmatically generate images with Apple's on-device models: concepts (text / extracted-text / image / drawing), up to 4 images per request, **styles limited to Apple's house set — `animation`, `illustration`, `sketch`** ([createwithswift breakdown](https://www.createwithswift.com/generating-images-programmatically-with-image-playground/)). iOS 26 (shipping fall 2025) added ChatGPT-powered styles (Oil Painting, Vector, Anime, "Any Style") — **but those route to OpenAI's cloud with per-user consent and token limits** ([9to5Mac](https://9to5mac.com/2025/06/10/image-playgrounds-gets-chatgpt-integration/)), which violates Addendum's no-servers law and adds an external dependency. iOS 27 reportedly brings "major" model-quality upgrades and third-party model support ([9to5Mac, May 2026](https://9to5mac.com/2026/05/24/apple-image-playground-and-gemoji-to-get-major-visual-improvements/)).

**The trade in one line: zero app-size cost, zero licensing cost, Apple-managed safety — in exchange for total style lock-in to Apple's aesthetic and a brutal device gate.**

- **Device gate:** Apple Intelligence hardware only — iPhone 15 Pro and newer, M-series iPads/Macs. The game targets broad reach; this excludes the iPhone 12–15 (non-Pro) installed base entirely, and errors (`notSupported`, `unavailable`) must be handled as a *normal* case, meaning generation can only ever be optional garnish.
- **Style:** Apple's three styles are glossy-3D-Pixar-ish / flat illustration / sketch. The just-locked design language (light, chunky-cute, ONE specific retro-cartoon style) cannot be expressed; no LoRA, no style reference enforcement. Apple-style brand logos sitting next to the authored card art is the definition of style mush.
- **Content behavior:** opinionated refusals (face-size errors, language errors, `backgroundCreationForbidden` — no background generation), no logo/wordmark competence, output rights undocumented.
- **Android equivalent: none.** There is no platform image-generation API on Android in mid-2026. Gemini Nano / ML Kit GenAI do text and image *understanding*, not generation. [MediaPipe Image Generator](https://developers.google.com/edge/mediapipe/solutions/vision/image_generator/android) (SD 1.5-architecture, LoRA support, ~15 s on 2023 *flagships*, 8 GB RAM recommended) is officially **"no longer actively maintained."** The remaining Android paths are DIY ONNX Runtime / Qualcomm QNN with per-chipset compiled binaries ([Qualcomm AI Hub](https://huggingface.co/qualcomm/Stable-Diffusion-v2.1)) — flagship-NPU-only, fragmentation hell. Using ImageCreator would make iOS-Pro devices a different game than every other device. That's a design-language and fairness fork, not a feature.

---

## 4. Style control: can a LoRA lock ONE cartoon style?

- **Training is cheap and known territory:** a style LoRA wants 20–50 curated images in the target style; ~15–60 min on an RTX 4090 / ~$1.40–$5 on cloud services ([guide](https://www.propelrc.com/how-to-train-stable-diffusion-lora-models/)). Since the design-language exploration batch already exists as generated imagery, the training set is nearly free.
- **On-device application:** Apple's Core ML pipeline has **no runtime LoRA support** — the LoRA must be merged into the base weights *before* conversion (standard practice; means one baked style per shipped model, which is actually what Addendum wants). MediaPipe (Android) supports LoRA but is unmaintained.
- **The honest catch:** style adherence degrades at 1–4 step inference — turbo/distilled models trade prompt- and style-fidelity for speed, and small base models hold fine style worse than SDXL-class. Expect "in the neighborhood" consistency, not the pixel-tight token discipline the design-language ruling demands (one icon set, one weight, color-law). Off-style generations *will* occur and there is no human curation step at runtime — that is the entire difference from the author-time pipeline.
- **Worst case is the headline use case:** diffusion models at this size class are *bad at logos and wordmarks* — clean vector shapes and legible text are the canonical failure mode. "Generate the brand's logo" is the single weakest application of this entire technology tier. Brand *mascots / product shots / ad scene art* are plausible; logos are not.

---

## 5. Integration: Defold + Core ML

- **No precedent found** — no Defold/Core ML extension exists publicly. Defold native extensions are C++/Obj-C; the team has confirmed **no Swift support in extensions and none planned** ([forum, Defold team](https://forum.defold.com/t/native-extension-swift-support/76851)).
- Core ML has a full Obj-C API, so the *engine* binding is feasible without Swift. But Apple's reference `StableDiffusion` pipeline (scheduler, tokenizer, pipeline orchestration) is Swift-only — the realistic route is compiling it as a static framework with an `@objc` bridge, linked via `ext.manifest` (Swift runtime libs on Defold's cloud builders: untested; the week-one local extender Docker becomes mandatory). Alternative: reimplement the scheduler loop in Obj-C++ (more work, fewer unknowns).
- **Effort estimate: 2–4 weeks of native plumbing** before any UX exists — bridge, model asset management (download, integrity, versioning), background-thread inference with progress callbacks into Lua, jetsam-pressure handling, cancellation. Compare: the haptics extension was budgeted 2–4 *days*. This is the single largest native-code line item the project would have, for either platform — and Android would be a *separate*, larger effort (ONNX/QNN per-chipset).
- **UX of 10–30 s waits:** a one-time "the agency's design department is working" ceremony at run-start could genuinely work as theater *on new-Pro iPhones* (1–4 s with sd-turbo). On an iPhone 12 it's 15–20 s; on mid-range Android it's minutes (see §7). A ceremony whose length varies 50× by device is not a ceremony, it's a loading screen apology.
- **Content safety / App Review:** Apple's 2025 age-rating overhaul makes developers account for AI-generated content frequency in ratings ([Apple](https://developer.apple.com/news/?id=ks775ehf)); apps with user-influenced generation are expected to have moderation/reporting affordances. Mitigation if ever shipped: **fixed prompt templates only, zero player free-text into the generator** — then the generation is developer-constrained content, not UGC, and the questionnaire answers stay clean. Note Apple's own converted SD pipeline bundles a 608 MB SafetyChecker model; dropping it (prompt-constrained) is defensible but is a judgment call App Review could disagree with.

---

## 6. App-size math

Real numbers from Apple's own converted, 6-bit-palettized SD 1.5 ([apple/coreml-stable-diffusion-v1-5-palettized](https://huggingface.co/apple/coreml-stable-diffusion-v1-5-palettized)):

| Component | Size |
|---|---|
| UNet | 645 MB |
| TextEncoder | 140 MB |
| VAE decoder + encoder | 167 MB |
| (SafetyChecker) | (608 MB) |
| **Generation-essential total** | **~952 MB** |
| Compiled distribution zip (incl. safety checker) | 1.46 GB |

sd-turbo is the same size class (SD 2.1-base architecture). Apple's mixed-bit palettization research can push the UNet toward ~2.5–4 bits (~300–430 MB) with visible quality cost — call the realistic floor **~600 MB total**, i.e. **4–6× the entire 150 MB budget, 6–10× the 100 MB target** for the whole game. In-bundle shipment is arithmetic nonsense.

**The ODR/PAD "loophole" is real but doesn't save it:**
- iOS On-Demand Resources, iOS 18+: 8 GB per asset pack, no in-use limit, 70 GB hosted ([Apple](https://developer.apple.com/help/app-store-connect/reference/on-demand-resources-size-limits/)) — a 1 GB optional model pack is *technically* trivial. (Apple now steers new work to Background Assets; same story.)
- Google Play Asset Delivery: 500 MB base module, 4 GB install-time cumulative, **30 GB** on-demand/fast-follow cumulative ([Google](https://support.google.com/googleplay/android-developer/answer/9859372)) — also technically fine.
- Apple 2.5.2 is **not** violated: model weights are data, not executable code — same legal footing as the planned Live Update card packs.
- But: a premium $7.99 game whose headline feature requires a post-purchase ~1 GB download, works on iPhone 13+/flagship-Android only, and drains battery/thermals, has shipped its dynamism behind three asterisks. The budget's *spirit* (respect the player's storage, work everywhere) is the thing being dodged.

---

## 7. The 3-year-old mid-range Android floor — the brutal part

This is where the idea dies, independent of everything above. "3-year-old mid-range" in June 2026 means a 2023 device: Snapdragon 695 / 6 Gen 1 / Dimensity 7050-class, 6–8 GB RAM, no usable NPU path.

- MediaPipe's own guidance: **~15 s per image on 2023 *high-end* devices** (Pixel 8 / S23-class) and an **8 GB RAM recommendation** ([Google](https://developers.googleblog.com/mediapipe-on-device-text-to-image-generation-solution-now-available-for-android-developers/)) — and that task is now unmaintained.
- The NPU fast path (5–10 s on Snapdragon 8 Gen 3, sub-second marketing demos on 8 Elite) requires Qualcomm QNN context binaries compiled **per flagship chipset** ([Qualcomm AI Hub](https://huggingface.co/qualcomm/Stable-Diffusion-v2.1), [Hackster](https://www.hackster.io/news/qualcomm-promises-to-power-on-device-ai-with-snapdragon-8-gen-3-shows-off-sub-second-stable-diffusion-419332bfa9ef)). Mid-range Adreno 619-class GPUs fall back to CPU/GPU inference: **multi-minute generations** ([community reporting](https://grokipedia.com/page/Stable_Diffusion_on_Android)), sustained at full SoC load — the exact opposite of the no-visible-throttle-in-30-minutes gate.
- A 6 GB device gives an app ~2–3 GB before the low-memory killer; SD-class inference peaks near or past that *while the game is also resident*.

**Conclusion: on the locked device floor, runtime diffusion fails on latency (10–60×), memory, and thermals simultaneously.** Any design where generation is *load-bearing* (every run needs it) is dead. Only a design where generation is *optional cosmetic garnish on high-end devices* survives — and that's a lot of native engineering for garnish.

### Determinism footnote

Art is exempt from sim determinism, but note: Core ML/ANE float behavior is not bit-stable across chip generations or OS versions — the same seed produces *different images on different devices*. Shared seeds and screenshot culture ("look at my run") would show different brands for the same run. The layered system composes identical assets everywhere; generation doesn't.

---

## 8. The embedding-model sidebar

An on-device embedding model (CLIP-class) for "visual understanding" of compositions:

- **Apple MobileCLIP is not shippable**: weights are under the Apple ML Research license — *"'Research Purposes' does not include any commercial exploitation, product development or use in any commercial product or service"* ([license](https://huggingface.co/apple/MobileCLIP-B-LT/blob/main/LICENSE)). SigLIP / OpenCLIP variants (Apache/MIT) are shippable at ~80–350 MB.
- **But it solves a non-problem.** Every layer in the layered art system is an *authored asset with authored metadata* (subject, setting, mood, tags). The sim can know everything about a composition from its tags, deterministically, at zero bytes and zero milliseconds. An embedding model is for understanding images you've never seen — Addendum has no such images unless it first ships the generator. Skip.

RimWorld-style brand *naming/simulation* likewise needs no ML: RimWorld's names come from grammar templates. A seeded name grammar (vertical-flavored morphemes: "Glow", "-ly", "Co.", "Lab") + the existing PRNG substreams gives infinite deterministic brands for ~10 KB of Lua and data. This is the actual RimWorld lesson — RimWorld generates *stories from systems and names from grammars*, not pixels from models.

---

## 9. What beats the baseline (and what doesn't)

The bar: the layered art system already yields combinatorial visuals (settings × people × products), deterministically, in-budget, in ONE style, with human curation of every atom. To ship, an ML tier must beat that. Scorecard:

| Path | Size | Floor devices | Style law | Verdict |
|---|---|---|---|---|
| **Layered baked assets + seeded recolor/palette/decal shaders + name grammar** | ~0 extra | all | perfect | **Do this. It IS the roguelike dynamism.** |
| Author-time generation (already planned) feeding more layer atoms each content patch (Live Update data packs) | 0 runtime | all | curated | **Do this — it's "generative" where it's safe: offline.** |
| ImageCreator vanity tier (e.g., player's custom client portrait), iOS-Pro-only, post-v1 | 0 MB | iPhone 15 Pro+ | violated (Apple styles) | Park. Re-evaluate after iOS 27 if styles open up. |
| sd-turbo + merged style LoRA via ODR/PAD, fixed prompts, run-start ceremony | +600 MB–1 GB DL | iPhone 13+ / flagship Android | approximate, uncurated | Post-v1 experiment at best; never load-bearing. 2–4 wk native + content-safety surface. |
| Runtime generation as core run identity (logos, every ad visual) | — | fails floor | fails | **Dead. Logos are the worst case; Android floor is fatal.** |

The roguelike feeling Shane wants — "no two runs look alike" — is a function of *combinatorial space × naming × economy state*, not of novel pixels. Balatro has zero generated art. RimWorld has zero generated art. Both feel infinite.

---

## Sources

- [apple/ml-stable-diffusion README (benchmarks, palettization, memory)](https://github.com/apple/ml-stable-diffusion/blob/main/README.md) · [repo status](https://github.com/apple/ml-stable-diffusion)
- [apple/coreml-stable-diffusion-v1-5-palettized file manifest](https://huggingface.co/apple/coreml-stable-diffusion-v1-5-palettized)
- [Draw Things wiki: device power/thermals](https://wiki.drawthings.ai/wiki/How_Powerful_Is_My_Device) · [Metal FlashAttention engineering post](https://engineering.drawthings.ai/p/integrating-metal-flashattention-accelerating-the-heart-of-image-generation-in-the-apple-ecosystem-16a86142eb18)
- [sd-turbo model card + Community License](https://huggingface.co/stabilityai/sd-turbo) · [SDXL-Turbo LICENSE](https://huggingface.co/stabilityai/sdxl-turbo/blob/main/LICENSE.md) · [Stability license page](https://stability.ai/license)
- [SD 1.5 current home + OpenRAIL-M](https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-v1-5) · [runwayml takedown discussion](https://huggingface.co/lllyasviel/control_v11p_sd15_inpaint/discussions/16)
- [ByteDance/SDXL-Lightning LICENSE (OpenRAIL++)](https://huggingface.co/ByteDance/SDXL-Lightning/blob/main/LICENSE.md) · [SDXS repo](https://github.com/IDKiro/sdxs) · [NVlabs/Sana](https://github.com/NVLabs/Sana)
- [ImageCreator docs](https://developer.apple.com/documentation/ImagePlayground/ImageCreator) · [createwithswift ImageCreator guide](https://www.createwithswift.com/generating-images-programmatically-with-image-playground/) · [iOS 26 ChatGPT styles — 9to5Mac](https://9to5mac.com/2025/06/10/image-playgrounds-gets-chatgpt-integration/) · [iOS 27 image-model upgrades — 9to5Mac](https://9to5mac.com/2026/05/24/apple-image-playground-and-gemoji-to-get-major-visual-improvements/)
- [MediaPipe Image Generator (Android) — unmaintained notice, 8 GB RAM, LoRA](https://developers.google.com/edge/mediapipe/solutions/vision/image_generator/android) · [launch post (~15 s on high-end)](https://developers.googleblog.com/mediapipe-on-device-text-to-image-generation-solution-now-available-for-android-developers/)
- [Qualcomm AI Hub Stable Diffusion](https://huggingface.co/qualcomm/Stable-Diffusion-v2.1) · [Hackster on sub-second Snapdragon demo](https://www.hackster.io/news/qualcomm-promises-to-power-on-device-ai-with-snapdragon-8-shows-off-sub-second-stable-diffusion-419332bfa9ef) · [Stable Diffusion on Android overview](https://grokipedia.com/page/Stable_Diffusion_on_Android)
- [Defold forum: no Swift in native extensions (team response)](https://forum.defold.com/t/native-extension-swift-support/76851)
- [Apple ODR size limits](https://developer.apple.com/help/app-store-connect/reference/on-demand-resources-size-limits/) · [Google Play size limits](https://support.google.com/googleplay/android-developer/answer/9859372)
- [Apple age-rating update (AI content consideration)](https://developer.apple.com/news/?id=ks775ehf) · [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [LoRA style training cost/process guide](https://www.propelrc.com/how-to-train-stable-diffusion-lora-models/)
- [MobileCLIP weights license (research-only)](https://huggingface.co/apple/MobileCLIP-B-LT/blob/main/LICENSE)
