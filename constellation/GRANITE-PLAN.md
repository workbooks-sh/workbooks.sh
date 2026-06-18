# Granite on ephemeral Fly CPU microVMs — cold-start / TTFT engineering plan

**Scope:** Serve IBM Granite (Q4_K_M GGUF, llama.cpp) one-model-per-microVM on Fly Machines (Firecracker-class), scale-to-zero, with the fastest possible cold-start → time-to-first-token (TTFT). Plus the GGUF mixture-of-experts angle. Measured baseline (given, not re-derived): Granite-3B-Q4_K_M ≈ **34 tok/s** generation at 4 threads on `shared-cpu-8x` (AVX2, no AVX-512). Models ≈ 2 GB (3B) / 5.3 GB (8B).

---

## Executive summary (read this first)

- **Warm-loading answer (the suspend/resume question): YES, Fly has it — but it is capped at ≤ 2 GB machine RAM, which our 2 GB model does *not* fit under.** `auto_stop_machines = "suspend"` snapshots the whole Firecracker VM (CPU registers + **memory contents** + open FDs) and resumes in **a few hundred ms** vs **~2+ s** cold boot — meaning the model stays paged-in RAM across idle. But Fly requires **≤ 2 GB memory** to suspend (and "discourages" it above that for snapshot-write time). A 3B-Q4 needs ~2 GB weights + KV/compute buffers, so the VM must be 4 GB+ → **suspend is unavailable at our model size today.** ([suspend-resume docs](https://fly.io/docs/reference/suspend-resume/))
- **Therefore the realistic fast path is STOP + warm pool, not suspend.** Use `auto_stop_machines = "stop"`, `auto_start_machines = true`, and `min_machines_running = 1` so one machine is *always hot* (model resident) for the latency-sensitive region; overflow machines cold-start on demand. ([autostop-autostart](https://fly.io/docs/launch/autostop-autostart/))
- **The Fly proxy holds the request during a start** — it buffers (≤10 MB), starts the stopped machine, and routes to it, so the client sees latency, not a 503. ([fly-replay/proxy](https://fly.io/docs/networking/dynamic-request-routing/), [error codes](https://fly.io/docs/monitoring/error-codes/))
- **Bake the GGUF into the image, mmap it, `--no-warmup`.** Image-resident weights + `mmap` (default) let the kernel page in lazily so generation can start before the whole file is resident; `--no-warmup` skips the empty priming run. This is the single biggest cold-TTFT lever short of suspend.
- **MoE on CPU is real and cheap-per-token, but "routing" is NOT tunable** — top-k experts are fixed by the model. Granite **4.1's main line is *dense*** (3B/8B/30B); the MoE play is **Granite 4.0 H-Tiny (7B total / 1B active)** / **H-Small (32B/9B)** or **Qwen3-Coder-30B-A3B** — small active params give ~active-param decode speed at large-total RAM cost (the cold-start tax). ([Granite 4.1 docs](https://unsloth.ai/docs/models/ibm-granite-4.1), [Granite 4.0](https://docs.unsloth.ai/models/tutorials-how-to-fine-tune-and-run-llms/ibm-granite-4.0))

---

## 1. Fly cold-start optimization

### 1a. Scale-to-zero + warm pool (`auto_stop_machines` / `auto_start_machines` / `min_machines_running`)

`auto_stop_machines` takes **`"off"` / `"stop"` / `"suspend"`**; `auto_start_machines` is a boolean; `min_machines_running` is an integer floor **in the app's primary region only** (no effect on other regions). ([config syntax](https://fly.io/docs/launch/autostop-autostart/))

- `min_machines_running = 1` → one machine stays running = model already loaded = **warm TTFT** for the first concurrent user. This is your warm pool of size 1. Cost: you pay for 1 always-on machine's CPU+RAM.
- `min_machines_running = 0` → true scale-to-zero; *every* first request after idle pays cold-start. Cheapest, slowest first token.
- The proxy's **stop loop runs every few minutes and stops at most one machine per region per pass**, and uses `soft_limit` concurrency to decide excess capacity: `excess = num_machines − (num_over_soft_limit + 1)`. With a single machine it stops only on zero traffic. ([fly-proxy-autostop-autostart](https://fly.io/docs/reference/fly-proxy-autostop-autostart/))

### 1b. **Machine SUSPEND vs STOP — the key question**

**Suspend exists and is exactly "warm loading."** Per Fly: suspend uses **Firecracker snapshots to capture the entire VM state: CPU registers, memory contents, open file handles**, written to persistent storage; resume restores from the snapshot instead of cold booting, so the machine "picks up exactly where it left off, without rebooting the OS or restarting your app." Resume = **a few hundred ms** vs **~2+ s** cold boot, and is **faster than starting from stopped**. Enable via `auto_stop_machines = "suspend"` or `fly machine suspend <id>` / the API. Suspended machines bill **storage only** (no CPU/RAM), same as stopped. ([suspend-resume](https://fly.io/docs/reference/suspend-resume/))

**The constraints that kill it for us today:**

- **Memory must be ≤ 2 GB to suspend**; larger is "discouraged due to increased suspend times." A 2 GB GGUF + KV cache + runtime needs a 4 GB+ machine → **over the limit.**
- Also required: **no swap, no schedule, no GPU, machine updated since 2024-06-20.** Works in all regions (since 2024-07).
- **Snapshots are invalidated by:** any **deploy/new app version**, host migration, file corruption, system maintenance — and stopping a suspended machine discards the snapshot, forcing a cold boot next start. So even where it works it's not durable across deploys. ([suspend-resume](https://fly.io/docs/reference/suspend-resume/))
- A 2025-10 bug made tiny-machine resumes take >30 s; **fixed**, but it shows suspend latency isn't a hard guarantee. ([community: resume fix](https://community.fly.io/t/fixed-unreasonably-slow-resumes-of-suspended-machines/26207))

**Verdict:** suspend is the ideal "model stays in RAM" mechanism but is gated to ≤2 GB RAM. Two ways to exploit it: (i) serve only the **Granite-1B-class / sub-2GB-VM footprint** under suspend; or (ii) lobby/wait — the limit is policy, not physics. For 3B/8B, use **stop + `min_machines_running ≥ 1`** as the warm path. (Track: re-test suspend on a 4 GB machine periodically; Fly has signaled wanting to raise the cap.)

### 1c. How the proxy holds the request during start

Fly edge proxies **buffer requests up to 10 MB** to support replay/retry; when a request hits a stopped machine the proxy starts it and **routes the request to the newly started machine** — the client experiences the start latency rather than a failure. (Edge cases: a *recently*-stopped machine within a 5-min window can emit `PM11` so the edge retries elsewhere; requests >10 MB stop being bufferable → `PA01`.) For LLM calls, payloads are tiny, so the hold-and-route path applies cleanly. ([dynamic routing](https://fly.io/docs/networking/dynamic-request-routing/), [error codes](https://fly.io/docs/monitoring/error-codes/))

### 1d. Model placement: bake-in vs Volume vs runtime download

- **Bake the GGUF into the OCI image (recommended).** Weights are part of the rootfs the microVM boots; no attach step, no network fetch, and `mmap` pages them lazily from the image-backed block device. The 2 GB model inflates image size but Fly handles multi-GB images; pull is cached on the host after first deploy.
- **Fly Volumes**: persistent, region-pinned NVMe; avoids re-baking on model swaps, but a volume is **bound to one machine** and adds an attach/availability dimension. Use only if you swap fine-tunes frequently without redeploying.
- **Runtime download** (fetch from R2/HF at boot): worst cold-start — adds full 2 GB transfer to first-boot latency. Avoid for the hot path; acceptable only as a lazy fallback. (No doc claims a specific image-size cap that we'd hit at 2–6 GB; treat image bloat as a pull-time, not a hard-limit, concern.)

### 1e. mmap / `--no-warmup` / first-token tricks

- **`mmap` is on by default** in llama.cpp; `--no-mmap` forces a full read-into-RAM before serving. **Keep mmap on** for fast cold-start: pages fault in on demand, so decode of the first tokens can begin before the entire file is resident. ([server flags](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md))
- **`--no-warmup`** skips the empty priming forward pass (warmup is enabled by default) — saves a chunk of startup wall-clock at the cost of the *first real* request paying the page-in. For TTFT-on-first-request you usually still want warmup *on the warm pool machine* (pre-pages weights) but *off* on overflow machines where you'd rather not block boot.
- **`--mlock`** pins weights in RAM (no page-out) — good on the always-warm machine to keep the model hot; pointless on suspend-ineligible scale-to-zero boxes.
- **Readahead trick:** on a baked image, a `cat model.gguf > /dev/null` (or `vmtouch`) in the entrypoint *before* `--no-warmup` serving warms the page cache deterministically; combine with `mlock` on the warm machine.

### 1f. Realistic cold-start → first-token budget (2 GB Granite-3B-Q4)

| Path | Boot/restore | Model page-in to first token | **TTFT** |
|---|---|---|---|
| (a) **Cold boot + load** (scale-to-zero, image-baked, mmap, `--no-warmup`) | ~2+ s VM boot ([docs](https://fly.io/docs/reference/suspend-resume/)) | ~1–3 s to page enough of 2 GB to emit token 1 (NVMe-backed) | **~3–6 s** |
| (b) **Resume-from-suspend** (only if VM ≤2 GB — i.e. sub-3B model) | few hundred ms ([docs](https://fly.io/docs/reference/suspend-resume/)) | ~0 (RAM already populated) | **~0.3–0.7 s** |
| (c) **Warm machine** (`min_machines_running=1`, mlock) | 0 | 0 | **prompt-eval only** (sub-second for short prompts at 34 tok/s decode) |

(b) is the prize but blocked by the 2 GB cap for 3B; today our practical fast path is **(c) for the first user + (a) for overflow.**

---

## 2. GGUF mixture-of-experts on CPU (llama.cpp)

### 2a. Which MoE models are servable

- **Granite 4.1 main line is *dense*** — 3B / 8B / 30B, no MoE. ([Granite 4.1](https://unsloth.ai/docs/models/ibm-granite-4.1)) So "Granite 4.1 MoE" is a misnomer for the headline models; the MoE variants live in **Granite 4.0**.
- **Granite 4.0 H-Tiny: 7B total / 1B active** (hybrid Mamba-2 + MoE, edge-targeted); **H-Small: 32B total / 9B active.** GGUF available (bartowski/unsloth). ([Granite 4.0](https://docs.unsloth.ai/models/tutorials-how-to-fine-tune-and-run-llms/ibm-granite-4.0))
- **Qwen3-Coder-30B-A3B: 30B total / 3B active** — the canonical "3B-class decode at 30B RAM cost" CPU MoE for a coding domain.

### 2b. Expert placement flags + the RAM/speed tradeoff

CPU/low-RAM expert placement in llama.cpp:
- **`--cpu-moe`** — keep *all* MoE expert FFN weights on CPU.
- **`--n-cpu-moe N`** — keep experts of the first N layers on CPU.
- **`--override-tensor` / `-ot`** — regex-route tensors to a buffer type, e.g. `-ot "exps=CPU"` or `-ot "\.ffn_(up|gate|down)_exps\.weight=CPU"` to pin expert FFNs to CPU while attention/router stay elsewhere. ([server flags](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md), [MoE offload guide](https://huggingface.co/blog/Doctor-Shotgun/llamacpp-moe-offload-guide))

On a **CPU-only** microVM all tensors are already on CPU, so these flags matter mainly in GPU/hybrid setups. The CPU-serving MoE value prop is intrinsic: **only the active experts compute per token.** A 30B-A3B model does ~3B-worth of FLOPs per token → ~**3B-class decode speed**, but **all 30B params must be RAM-resident** because the router can pick any expert each token. Concretely for CPU microVM serving:

| Model | Active / Total | Decode speed class | RAM resident (Q4) | Cold-start hit |
|---|---|---|---|---|
| Granite-3B dense | 3B / 3B | ~34 tok/s (measured) | ~2 GB | small (page-in 2 GB) |
| Granite-4.0-H-Tiny | 1B / 7B | ~1B-class (fast) | ~4–5 GB | medium |
| Qwen3-Coder-30B-A3B | 3B / 30B | ~3B-class (~30ish tok/s class) | ~16–18 GB | **large** (page-in 16+ GB) |

So MoE buys you **bigger-model quality at small-model decode speed**, paid for in **RAM footprint and a proportionally worse cold-start** (more pages to fault in, definitely over the 2 GB suspend cap, needs an 8–16x / dedicated machine).

### 2c. Is routing tunable? (be honest)

**No.** Top-k expert routing is **fixed by the trained model architecture** — you cannot dial "use top-1 vs top-2 experts" at inference in stock llama.cpp; the router weights and k are baked in. ([MoE offload guide](https://huggingface.co/blog/Doctor-Shotgun/llamacpp-moe-offload-guide)) What *is* controllable: **where** expert tensors live (CPU/GPU via `-ot`/`--cpu-moe`) and quantization. "Fine-grained MoE routing" as a tunable inference knob is not a real llama.cpp lever — pick the model whose fixed routing you want.

---

## 3. Serving + measuring real concurrency

Your `llama-cli` wall-clock harness was **contaminated by per-invocation model reload** — each call re-loads ~2 GB, so "tok/s" included load time. Measure with a **persistent `llama-server`** and read throughput from the model, not the shell clock.

**Continuous batching** is **on by default** in llama-server; `--parallel/-np` sets slot count (default auto). Key truth: bumping `--parallel` without raising `--batch-size`/`--ubatch-size` just spreads the same aggregate throughput across more queues (latency up, aggregate flat). ([server flags](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md), [parallel tuning](https://github.com/ggml-org/llama.cpp/discussions/18308)) On CPU, aggregate scaling is modest (CPU-only benchmarks show roughly flat aggregate ~10 tok/s-class going sequential→concurrent on weak boxes — measure on *our* AVX2 8x). ([CPU server flags benchmark](https://tiffena.me/blog/llm-cpu-only-inference-benchmark-llama.cpp-server-flags/))

**Correct measurement:**
1. Start `llama-server --metrics` and scrape **`/metrics`** — it exposes `llamacpp:predicted_tokens_seconds` (generation tok/s) and `llamacpp:prompt_tokens_seconds`. ([server flags](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md))
2. For the per-config sweep, use **`llama-bench`** (warms once, reports pp/tg tok/s cleanly) — no reload contamination.
3. For aggregate concurrency, fire N parallel HTTP requests (e.g. `oha`/`vegeta` against `/completion`) and read aggregate generation tok/s from `/metrics`, not from client wall-clock.

---

## 4. Recommended stack

**Image layout** (single OCI image, weights baked):
```
/app/llama-server              # static build, AVX2 target (no AVX-512 on Fly shared)
/models/granite-3b-q4_k_m.gguf # baked in; mmap'd at runtime
/app/entrypoint.sh             # optional: vmtouch /models/*.gguf, then exec server
```

**`fly.toml`** (warm pool of 1 + scale-to-zero overflow; suspend left as a commented future path):
```toml
app = "granite-infer"
primary_region = "iad"

[build]
  dockerfile = "Dockerfile"

[[vm]]
  size = "shared-cpu-8x"
  memory = "4096"            # 2GB weights + KV/compute; >2GB so suspend N/A today

[http_service]
  internal_port = 8080
  force_https = true
  auto_start_machines = true
  auto_stop_machines = "stop"   # use "suspend" ONLY for sub-2GB-VM (≤1B) models
  min_machines_running = 1      # one always-warm machine = warm TTFT in primary region
  [http_service.concurrency]
    type = "requests"
    soft_limit = 4               # ~= --parallel; tune to measured aggregate
    hard_limit = 8
```

**`llama-server` command** (warm machine — pin + pre-warm; on overflow boxes drop `--mlock`, add `--no-warmup`):
```bash
/app/llama-server \
  --model /models/granite-3b-q4_k_m.gguf \
  --host 0.0.0.0 --port 8080 \
  --threads 4 \                # measured sweet spot on shared-cpu-8x (AVX2)
  --ctx-size 8192 \
  --parallel 4 \              # slots; cont-batching is on by default
  --batch-size 2048 --ubatch-size 512 \
  --mlock \                    # warm machine: keep model resident (omit on scale-to-zero)
  --metrics \
  --jinja                      # use the model's chat template
```

**Phased plan:**
- **(a) Re-measure correctly.** Deploy `llama-server`, run `llama-bench` for single-stream tg tok/s (expect ~34 confirm), then parallel load test reading `/metrics` for aggregate at `--parallel` 1/2/4/8 and `--threads` 3/4/6 — find the knee. Kill the per-invocation-reload harness.
- **(b) Optimize cold-start to budget.** Target **warm-machine TTFT < 1 s** (achieved via `min_machines_running=1` + `mlock`), **overflow cold TTFT ≤ ~4 s** (image-baked + mmap + `vmtouch` + `--no-warmup`). Spike a ≤2 GB-VM Granite-1B under `auto_stop_machines="suspend"` to validate the **~0.3–0.7 s resume** path for the latency-critical tier.
- **(c) Wire in the QLoRA fine-tune.** QLoRA-tune Granite for the Workbooks/Workponents/toolkit/org-mode DSL domain, **merge to fp16, then quantize to Q4_K_M GGUF** (`llama-quantize`), swap the baked file, redeploy. Keep base + adapter in CI so re-quant is one command.

**Rough $/M-token** (fill once (a) lands): on `shared-cpu-8x` at hourly price `P`, with measured warm aggregate `A` tok/s, cost ≈ `P / (A × 3600 / 1e6)` $/M output tokens. At a placeholder `A=34` single-stream and ~`$0.06/hr`-class shared-8x, that's ≈ **$0.49/M tok**; concurrency (aggregate `A` of e.g. 80–120 with 4 slots) drops it 2–3× → **~$0.15–0.25/M tok**. **Do not quote until (a) gives real aggregate `A`.**

---

## Open questions / risks

- **Suspend 2 GB cap is the central blocker** for sub-second resume on 3B+. Risk: it stays policy-locked. Mitigation: serve a ≤1B suspend tier for latency-critical calls; revisit the cap quarterly. ([suspend-resume](https://fly.io/docs/reference/suspend-resume/))
- **Snapshot invalidation on every deploy** — even a working suspend tier cold-boots after each model swap; fine-tune redeploys reset the warm RAM. ([suspend-resume](https://fly.io/docs/reference/suspend-resume/))
- **CPU concurrency may not scale aggregate throughput** much past 1–2 slots on AVX2-no-AVX512 — unverified on our box; (a) must measure. ([CPU benchmark](https://tiffena.me/blog/llm-cpu-only-inference-benchmark-llama.cpp-server-flags/))
- **MoE cold-start tax**: 30B-A3B needs ~16+ GB resident → big machine, slow page-in, no suspend. Only worth it if quality gap over dense-3B/8B justifies the cold-start and $.
- **"Recently stopped" 5-min `PM11` window** and the every-few-minutes stop loop add jitter to scale-to-zero TTFT tails — model the p99, not just p50. ([error codes](https://fly.io/docs/monitoring/error-codes/), [fly-proxy](https://fly.io/docs/reference/fly-proxy-autostop-autostart/))
- **Image size vs swap cadence**: baking weights bloats images; if fine-tunes ship daily, weigh Volumes despite their machine-pinning.

---
### Sources
- Fly Machine Suspend & Resume — https://fly.io/docs/reference/suspend-resume/
- Fly Autostop/Autostart (config) — https://fly.io/docs/launch/autostop-autostart/
- Fly Proxy autostop/autostart (semantics) — https://fly.io/docs/reference/fly-proxy-autostop-autostart/
- Fly dynamic request routing / fly-replay — https://fly.io/docs/networking/dynamic-request-routing/
- Fly error codes (PM11/PA01) — https://fly.io/docs/monitoring/error-codes/
- Fly community: resume-latency fix (Oct 2025) — https://community.fly.io/t/fixed-unreasonably-slow-resumes-of-suspended-machines/26207
- llama.cpp server flags/README — https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
- llama.cpp parallel/slot tuning — https://github.com/ggml-org/llama.cpp/discussions/18308
- llama.cpp MoE CPU-offload guide — https://huggingface.co/blog/Doctor-Shotgun/llamacpp-moe-offload-guide
- CPU-only llama-server flag benchmark — https://tiffena.me/blog/llm-cpu-only-inference-benchmark-llama.cpp-server-flags/
- IBM Granite 4.1 (dense 3B/8B/30B) — https://unsloth.ai/docs/models/ibm-granite-4.1
- IBM Granite 4.0 (H-Tiny 7B/1B MoE, H-Small 32B/9B) — https://docs.unsloth.ai/models/tutorials-how-to-fine-tune-and-run-llms/ibm-granite-4.0
