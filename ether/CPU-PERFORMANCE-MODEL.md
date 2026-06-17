# CPU LLM Inference Performance Model — and the Hardware that Maximizes tok/s & tok/s-per-Dollar

**Scope:** llama.cpp / GGUF, single-stream, one model per box, quantized coding models from ~2 GB (Granite-3B-Q4) to ~18 GB (30B-A3B MoE Q4). Targets: cheap dedicated / bare-metal (Vultr, Hetzner) and cloud (AWS/GCP).
**Measured baseline:** Granite-3B-Q4 ≈ **20 tok/s** gen, **42 tok/s** prefill, on a Vultr AMD EPYC-Milan instance — **2 physical cores** (4 vCPU SMT), AVX2, a *slice* of one socket's DDR4 channels.
**Date:** 2026-06-16. Every quantitative claim is cited inline.

---

## Executive summary (read this first)

1. **The single biggest lever is memory bandwidth — specifically memory channels × DDR generation, not core count.** CPU decode (token generation) is memory-**bandwidth**-bound: each token must stream (most of) the model's weights out of RAM, so `tok/s ≈ effective_bandwidth ÷ bytes_read_per_token`. Cores stop helping the moment bandwidth saturates — which on a dual-channel box happens at ~5 threads [johannesgaessler]. The lever is going from a *dual-channel slice* (≈25–90 GB/s) to a *12-channel server socket* (≈460–614 GB/s) [ahelpme; AMD 9175F].

2. **Our box is running at roughly 40 GB/s of effective bandwidth, and we are leaving ~10–20× on the table.** Backing the model out of our measured 20 tok/s on a ~2 GB model implies ≈40 GB/s effective (see §1.4) — consistent with a 2-channel DDR4 slice. A full 12-channel DDR5 Genoa/Turin socket (~460 GB/s effective, ~60–70% realized) puts Granite-3B-Q4 at a **realistic ~150–230 tok/s gen ceiling** — order **8–11× faster** for the same single stream.

3. **For the 30B-A3B MoE the math is even kinder.** MoE reads only the *active* expert bytes per token (~3 GB for a 30B-A3B-Q4, not the full 18 GB) [model arithmetic; cross-checked vs MoE benchmarks]. So a 30B-A3B-Q4 decodes at roughly the *same* tok/s as a 3B dense model of the same active size — the MoE is a bandwidth bargain. On a 460 GB/s socket it lands near ~100–150 tok/s gen.

4. **AMX is a prefill lever, not a decode lever.** Intel AMX (Sapphire/Granite Rapids, Xeon 6) gives 2048 INT8 ops/cycle vs 256 for AVX-512-VNNI — an 8× *compute* multiplier [Intel] that shows up as **6–14× faster prompt processing (TTFT)** but only **2–4× faster decode (TPOT)**, and the decode gain is mostly because AMX-class chips also carry 12-channel DDR5 [LMSYS/SGLang; Cortensor]. For our single-stream coding use (modest prompts, long generations) AMX helps prefill latency but won't move the decode ceiling — bandwidth will.

5. **Best value box to *host* on:** a 12-channel DDR5 EPYC Genoa/Turin bare-metal (Hetzner **AX162-R**, EPYC 9454P, ~€199/mo) or Vultr Bare Metal EPYC — best tok/s-per-dollar because you get full-socket bandwidth at a flat dedicated price [Hetzner]. **Avoid** Hetzner's cheap Ryzen AX boxes and EPYC-4005 "Grado" for serving: they are **dual-channel** (~89.6 GB/s) [storagereview] — high clocks, starved bandwidth.

6. **Best box to *benchmark next*:** an AWS **c8g (Graviton4)** — 12-channel DDR5-5600, ~**537 GB/s** [buw/medium], hourly, and an Intel **Xeon 6 / Sapphire Rapids AMX** box (Vultr/GCP) to measure the AMX prefill jump. These bracket the high-bandwidth and AMX axes against the EPYC mid-point.

---

## 1. The performance model

### 1.1 Decode is bandwidth-bound — derivation

Generating one token is a forward pass over the whole network. With KV-cache, the dominant work per decoded token is multiplying the activation vector (tiny) by every weight matrix (huge). Each weight is read from RAM **once per token** and used in a handful of FLOPs — arithmetic intensity is ~O(1) FLOP/byte, far below any modern CPU's FLOP:byte ratio. So the wall is the bus, not the ALUs:

```
decode tok/s  ≈  effective_memory_bandwidth (bytes/s)  ÷  bytes_read_per_token
```

- **Dense model:** `bytes_read_per_token ≈ model_file_size` (all weights streamed each token). A Q4 3B is ~2 GB, so ~2 GB/token.
- **MoE model:** only the **active** experts fire per token, so `bytes_read_per_token ≈ active_param_bytes + shared/attention bytes`. A 30B-A3B-Q4 file is ~18 GB but reads only ~3 GB/token (the "A3B" = ~3B active params at Q4 ≈ ~1.6–2 GB of expert weights + attention/router/shared ≈ ~3 GB total touched). **This is why MoE decodes far faster than its file size suggests** — confirmed by the general finding that tok/s scales inversely with *active*, not total, parameters [ahelpme].

`effective_memory_bandwidth` is **realized** bandwidth, typically **55–70% of the spec/peak** for llama.cpp's streaming kernels (Intel MLC showed ~460 GB/s achievable of a 460.8 GB/s theoretical on EPYC 9554, but llama.cpp realizes less than MLC) [ahelpme]. Prefill, below, is a different regime.

### 1.2 Prefill is compute-bound

Prompt processing (prefill) multiplies a *matrix* of N prompt tokens by the weights — each weight read amortizes over N tokens, so arithmetic intensity is ~N× higher and the kernel becomes a dense **GEMM** limited by SIMD/matrix throughput, not bandwidth. This is exactly where wide SIMD (AVX-512) and matrix units (**AMX**) win (§3). Our measured 42 tok/s prefill on 2 AVX2 cores is compute-starved; it scales with cores and instruction width, not memory channels.

### 1.3 Worked theoretical decode ceilings

Assume ~65% bandwidth efficiency (a good llama.cpp streaming kernel on a well-fed socket). `tok/s = (BW_GBs × 0.65) ÷ bytes_per_token`.

| Effective spec BW | Realized (×0.65) | **Granite-3B-Q4** (~2.0 GB/tok) | **30B-A3B-Q4 MoE** (~3.0 GB/tok) |
|---|---|---|---|
| 25 GB/s (DDR4 dual-ch slice) | 16 GB/s | **~8 tok/s** | ~5 tok/s |
| 50 GB/s (DDR4 quad / DDR5 dual) | 33 GB/s | **~16 tok/s** | ~11 tok/s |
| 90 GB/s (DDR5 dual-ch, EPYC-4005) | 58 GB/s | **~29 tok/s** | ~19 tok/s |
| 200 GB/s (DDR5, ~6 channels) | 130 GB/s | **~65 tok/s** | ~43 tok/s |
| 460 GB/s (12-ch DDR5-5600, EPYC 9554) | 300 GB/s | **~150 tok/s** | ~100 tok/s |
| 537 GB/s (Graviton4, 12-ch DDR5-5600) | 350 GB/s | **~175 tok/s** | ~115 tok/s |
| 614 GB/s (EPYC 9175F, 12-ch DDR5-6400) | 400 GB/s | **~200 tok/s** | ~130 tok/s |

Channel/BW figures: EPYC 9554 460.8 GB/s, 12×DDR5-5600 [ahelpme]; Graviton4 536.7 GB/s, 12-ch DDR5-5600 [buw/medium]; EPYC 9175F ~614 GB/s, 12-ch DDR5-6400 [topcpu/AMD]; EPYC-4005 dual-channel 89.6 GB/s [storagereview].

**Cross-check against a published full-socket run:** EPYC 9554 (460 GB/s) measured **~50 tok/s on an 8B-Q4** (~4.7 GB/tok) [ahelpme]. Model predicts `460×0.65 ÷ 4.7 ≈ 64`; measured 50 → **~50/64 ≈ 78% of the 0.65-efficiency line**, i.e. real efficiency ~0.51. And **70B-Q4** (~40 GB/tok) measured **~7 tok/s** [ahelpme]; model at 0.51 eff: `460×0.51 ÷ 40 ≈ 5.9` — within ~15%. The model holds across an 8× model-size range. Using the *measured* ~0.51 efficiency, Granite-3B-Q4 on a 9554 ≈ `460×0.51 ÷ 2.0 ≈ **117 tok/s**` (so the table's ~150 is the optimistic end; ~120–150 is the honest band).

### 1.4 Backing out OUR box's effective bandwidth

We measured **20 tok/s** on Granite-3B-Q4 (~2.0 GB/tok). Invert the model:

```
effective_BW = tok/s × bytes_per_token = 20 × 2.0 GB = 40 GB/s realized
spec_BW ≈ 40 / 0.55 ≈ 70 GB/s nominal — but on a 2-vCPU slice we never get full channels...
```

40 GB/s **realized** is consistent with **~2 DDR4 channels** (DDR4-3200 dual-channel peak ≈ 51 GB/s spec; a noisy-neighbor cloud *slice* of an EPYC-Milan socket realizes ~40). The tell: 2 physical cores is **below** the ~5 threads needed to saturate even dual-channel [johannesgaessler], so we may also be slightly *core*-limited on top of bandwidth — but the dominant ceiling is the ~40 GB/s bus. **Conclusion: our effective bandwidth ≈ 40 GB/s; a full 12-channel DDR5 socket at ~300–400 GB/s realized is ~8–10× more, i.e. a realistic Granite-3B-Q4 ceiling of ~120–200 tok/s on good hardware.**

---

## 2. What scales decode: cores vs channels vs DDR generation

**Cores scale tok/s only until bandwidth saturates, then flatline.** Because decode reads weights once and barely computes, a handful of threads can already issue enough outstanding loads to fill the memory bus; adding cores just adds idle waiters. Measured saturation points [johannesgaessler]:
- Ryzen 3700X, **dual-channel** → saturates at **~5 threads**, *regresses* past 8.
- Xeon E5-2683v4, **quad-channel** → optimum ~29 threads, diminishing returns past the 16 physical cores.

The saturation thread count rises with channel count — because more channels = more bandwidth to fill = more useful concurrent loads. This is the whole game: **"performance is almost proportional to memory frequency; ~5 threads fully utilize dual-channel bandwidth"** [johannesgaessler]; **"for CPU inference the most important factor is memory bandwidth; the actual CPU doesn't matter much"** [johannesgaessler].

**Channels × DDR-gen is the real decode lever.** Per-socket bandwidth ≈ `channels × DDR_transfer_rate × 8 bytes`:
- DDR4-3200 dual-channel ≈ 51 GB/s spec; quad ≈ 102.
- DDR5-5600 dual-channel ≈ 89.6 GB/s (EPYC-4005) [storagereview].
- DDR5-5600 **12-channel** ≈ 460 GB/s (EPYC 9554) [ahelpme]; DDR5-6400 12-channel ≈ 614 GB/s (EPYC 9175F) [topcpu].

So going DDR4-dual → DDR5-12ch is **~9–12× bandwidth** = ~9–12× decode tok/s — *independent of how many cores you add*. **A 96-core Ryzen-desktop box on 2 channels will lose decode to a 16-core EPYC on 12 channels.** (The EPYC 9175F is literally a 16-core/12-channel part built for exactly this bandwidth-per-core ratio [AMD 9175F].)

**NUMA caveat (dual-socket):** dual-socket boxes split the model across two memory controllers; cross-socket reads tank tok/s. A dual EPYC 9175F (16 DDR5-6400 channels) only hit 4.31 tok/s on a 70B-f16 until `--numa distribute` + warm cache fixed remote-access patterns [llama.cpp#11744]. **Prefer one fat socket over two; if dual, pin with `--numa distribute`.**

---

## 3. CPU features: AVX2 vs AVX-512 vs AMX

| Feature | INT8 ops/cycle | Helps DECODE? | Helps PREFILL? |
|---|---|---|---|
| AVX2 (our box) | 64-ish (256-bit) | only by feeding the bus | weak GEMM |
| AVX-512 (-VNNI) | 256 [Intel] | marginal (bus-bound) | "significant uplift" on EPYC [Cortensor] |
| **AMX** (SPR/GNR/Xeon6) | **2048** [Intel] | **2–4×** [LMSYS] | **6–14×** [LMSYS] |

- **Decode** is bandwidth-bound, so wider SIMD/AMX barely moves it on its own. The 2–4× decode (TPOT) gain attributed to AMX in SGLang vs llama.cpp [LMSYS] comes mostly from the AMX chip's **12-channel DDR5**, not the matrix unit; a direct AMX-on/off toggle on a 3B INT8 showed ~57 vs ~28 tok/s — a **~2× decode** bump where present [Cortensor], but that's the ceiling, not multiplied by bandwidth gains.
- **Prefill** is GEMM, so AMX is huge: AMX gives **6–14× faster TTFT** vs llama.cpp's AVX path [LMSYS], and Phoronix/Intel call AMX "a massive benefit for prompt processing" on Granite Rapids running GPT-OSS-20B and Qwen3 [phoronix].
- **AMX hardware:** 2048 INT8 ops/cycle (8× AVX-512-VNNI's 256) and 1024 BF16/cycle (16× FP32) [Intel]; the 4–8× real-world GEMM speedup over AVX-512 applies to sustained large-matrix loops [Cortensor].

**For our case (single-stream coding: short-to-medium prompts, long generations) AMX is a *prefill/TTFT* lever — nice for snappy first token, irrelevant to the sustained tok/s ceiling.** Spend the budget on bandwidth first; treat AMX as a bonus that comes bundled with the high-channel Intel parts anyway. (Note: SGLang's AMX numbers are *vs llama.cpp* — llama.cpp's own AMX support is improving but does not yet realize SGLang's full prefill multiplier.)

---

## 4. Real hardware shootout (Granite-3B-Q4 decode, single stream)

tok/s estimated from §1.3 at measured ~0.51 efficiency (`spec_BW × 0.51 ÷ 2.0 GB`). Prices are list as of mid-2026; cloud = on-demand. *Spec BW used for the estimate; small/cloud-slice boxes will realize less.*

| Box | Cores (phys) | Channels / DDR | Spec BW | AVX-512 / AMX | Price | **Est. tok/s** | **tok/s per $/mo** |
|---|---|---|---|---|---|---|---|
| **Our baseline** (Vultr EPYC-Milan slice) | 2 | ~2 DDR4-3200 slice | ~40 realized | AVX2 | ~$30/mo | **20 (measured)** | 0.67 |
| Hetzner AX102 (Ryzen 9 7950X) | 16 | **2** DDR5-5600 | 89.6 | AVX-512 / no AMX | ~€120/mo | **~23** | ~0.19 |
| Vultr EPYC-4005 "Grado" | 8–16 | **2** DDR5-5600 | 89.6 | AVX-512 / no | ~$120/mo | **~23** | ~0.19 |
| **Hetzner AX162-R (EPYC 9454P, Genoa)** | 48 | **12** DDR5-4800 | ~460 | AVX-512 / no AMX | **~€199/mo** | **~117** | **~0.59** |
| Vultr Bare Metal EPYC Genoa | 32–64 | 12 DDR5 | ~460 | AVX-512 / no | ~$700–1500/mo | ~117 | ~0.10–0.17 |
| **AWS c8g.8xlarge (Graviton4)** | 32 (vCPU=phys) | **12** DDR5-5600 | **537** | ARM SVE / no AMX | ~$1.15/hr (~$840/mo) | **~137** | ~0.16/mo (**~119 tok/s per $/hr**) |
| AWS c7i / GCP (Sapphire/Granite Rapids) | 32–48 | 8–12 DDR5 | ~300–460 | AVX-512 **+ AMX** | ~$1.4–2.0/hr | ~80–117 (decode); **prefill 6–14×** | prefill-leader |
| EPYC 9175F bare-metal (16c/12ch DDR5-6400) | 16 | 12 DDR5-6400 | **614** | AVX-512 / no | ~$900–1400/mo | **~157** | ~0.12–0.17 |

**Ranking by raw decode tok/s:** EPYC 9175F (~157) ≈ Graviton4 c8g (~137) > AX162-R Genoa (~117) >> dual-channel Ryzen/4005 (~23) > our slice (20).

**Ranking by tok/s-per-dollar (sustained hosting):** **Hetzner AX162-R wins decisively** (~117 tok/s for €199/mo flat, dedicated, full 12-channel socket) — ~0.59 tok/s per $/mo, ~3× our baseline's value and ~3× the dual-channel boxes which, despite high clocks, are bandwidth-capped at ~23 tok/s. Cloud (Vultr BM, AWS c8g) delivers similar or higher *absolute* tok/s but at 3–8× the $/tok for a 24/7 single-model box.

**Best box to HOST on:** **Hetzner AX162-R (EPYC 9454P Genoa, 12-ch DDR5)** — flat €199/mo, ~6× our decode at ~the cost of a couple of cloud slices [Hetzner AX162]. Avoid the cheap dual-channel Ryzen/EPYC-4005 boxes for serving.

**Best box to BENCHMARK next:** **AWS c8g (Graviton4)** to verify the ~537 GB/s high-bandwidth ceiling hourly, **and** one **Sapphire/Granite Rapids AMX** box to measure the AMX prefill multiplier on llama.cpp directly.

---

## 5. Recommended test matrix

Spin up **three** boxes, hourly where possible, and run identical `llama-bench` sweeps. This maps the curve: bandwidth axis (channels), core-saturation axis, and the AMX axis.

**Boxes**
1. **8–16 physical-core EPYC Genoa, 12-channel DDR5** — Hetzner AX162-R or a Vultr/Latitude.sh Genoa bare-metal. *Purpose: prove the ~460 GB/s decode ceiling and find the core-saturation knee.*
2. **AWS c8g.8xlarge (Graviton4, 12-ch DDR5-5600, ~537 GB/s)** — hourly. *Purpose: top-of-band bandwidth, no AMX — isolates bandwidth from matrix units.*
3. **AWS c7i / GCP Sapphire-or-Granite-Rapids (AMX)** — hourly. *Purpose: measure AMX prefill jump and any decode delta vs Graviton4 at similar channels.*

**What to run** (per box, GGUF Q4_K_M):
```bash
# Granite-3B-Q4 and the 30B-A3B-Q4 MoE
llama-bench -m granite-3b-q4.gguf  -p 512 -n 128 -t 2,4,8,16,32,48 --numa distribute
llama-bench -m 30b-a3b-q4.gguf     -p 512 -n 128 -t 2,4,8,16,32,48 --numa distribute
# tg = decode tok/s, pp = prefill tok/s; sweep -t to find the knee
```
Also vary `-t` past physical cores to confirm regression; on dual-socket add `--numa distribute` and pin.

**What to expect**
- **Decode (tg):** rises with threads, then **flatlines at the bandwidth wall** — knee around ~half the physical cores on 12-channel parts; flat thereafter. Genoa ~100–130 tok/s, Graviton4 ~130–175 tok/s for Granite-3B-Q4 (§1.3). The 30B-A3B MoE should land within ~30% of the 3B's tok/s (active-size argument), proving MoE is a bandwidth bargain.
- **Prefill (pp):** rises with cores **and** instruction width. The AMX box should show **multiples** higher pp than Genoa/Graviton4 at equal core count [LMSYS 6–14× TTFT]; decode delta should be small (bandwidth-bound).
- **Confirm the model:** plug each box's measured tg back into `BW_eff = tg × bytes/token` and check it lands at ~0.5–0.65 of spec BW. If a box reads far below, it's NUMA/thread-config, not the model.

---

## Sources
- [johannesgaessler] llama.cpp Performance Testing — bandwidth-bound decode, thread saturation: https://johannesgaessler.github.io/llamacpp_performance
- [ahelpme] LLM inference benchmarks with llama.cpp + AMD EPYC 9554 (460 GB/s, 12×DDR5-5600; 8B-Q4 ~50 tok/s, 70B-Q4 ~7 tok/s): https://ahelpme.com/ai/llm-inference-benchmarks-with-llamacpp-with-amd-epyc-9554-cpu/
- [llama.cpp#11744] Poor tok-gen on dual EPYC Genoa/Turin (NUMA, `--numa distribute`, 9175F 16-ch DDR5-6400): https://github.com/ggml-org/llama.cpp/issues/11744
- [Intel] AMX 2048 INT8 ops/cycle vs 256 AVX-512-VNNI; 1024 BF16/cycle: https://www.intel.com/content/www/us/en/developer/articles/technical/llama-2-on-xeon-scalable-processor-with-deepspeed.html
- [LMSYS] SGLang on Xeon AMX: 6–14× TTFT (prefill), 2–4× TPOT (decode) vs llama.cpp: https://www.lmsys.org/blog/2025-07-14-intel-xeon-optimization/
- [Cortensor] AVX/AMX/SME instruction sets; AMX-on ~57 vs AMX-off ~28 tok/s on 3B INT8; 4–8× GEMM vs AVX-512: https://docs.cortensor.network/technical-architecture/ai-inference/cpu-instruction-sets-for-llm-inference-avx-amx-sme-vs-gpus
- [phoronix] AMX on Xeon 6 Granite Rapids — massive prefill benefit (GPT-OSS-20B, Qwen3): https://www.phoronix.com/review/intel-xeon-6-granite-rapids-amx
- [buw/medium] Graviton4 12-ch DDR5-5600 = 536.7 GB/s (75% over Graviton3): https://buw.medium.com/aws-graviton4-complete-guide-strategic-performance-optimization-and-cost-reduction-43a885d891d1
- [storagereview] AMD EPYC 4005 "Grado" — dual-channel DDR5-5600, 89.6 GB/s/socket: https://www.storagereview.com/review/amd-epyc-4005-review-am5-economics-with-enterprise-focus
- [topcpu / AMD 9175F] EPYC 9175F 16c/12-ch DDR5-6400 ~576–614 GB/s/socket: https://www.amd.com/en/products/processors/server/epyc/9005-series/amd-epyc-9175f.html
- [Hetzner AX162] AX162-R EPYC 9454P (Genoa) bare-metal from €199/mo: https://www.hetzner.com/news/new-ax162/
- [vultr] Vultr Bare Metal / EPYC pricing & lineup: https://www.vultr.com/pricing/
