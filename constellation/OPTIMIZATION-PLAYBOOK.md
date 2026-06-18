# Granite-4.1-3B CPU Inference — Optimization Playbook

**Actionable companion to `GRANITE-EFFICIENCY.md`.** That doc maps the model lineup and a first
optimization pass; this one is the *runbook* — exact commands, exact flags, an ordered experiment
plan with expected deltas, and what to measure — for **our validated box**.

**Validated baseline (measured, do not re-derive):** Granite-4.1-3B-Q4_K_M on llama.cpp `llama-server`,
Vultr dedicated AMD EPYC-Milan, **4 vCPU = 2 physical cores + SMT**, AVX2 (no AVX-512/VNNI), 8 GB, Ubuntu 24.04.
Decode **22 tok/s @ 4 threads** (13.7 @ 2 threads), prefill **42 tok/s**, TTFT ~660 ms short prompt,
~2.6 GB RSS. Single-stream, one model/box, persistent (no cold-start). Use case: code/DSL authoring
(Workbooks single-file HTML, Lit `wb-*` components, toolkits, org-mode); QLoRA fine-tune planned.

---

## Executive summary — ranked by expected win for OUR box

1. **Prompt/KV caching for the fixed system+DSL prefix = the single biggest practical win (TTFT → ~0 on the cached prefix).** Our prefill is 42 tok/s; a 1,500-token DSL preamble costs **~36 s of prefill on a cold slot**. `--cache-prompt` (default ON) + persistent slot reuse means that prefix is processed **once** and every later request pays prefill only on the *changed suffix*. This is a **10–100× TTFT reduction on repeat requests**, free, zero RAM cost. Do this first. ([server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md))
2. **Prompt-lookup (n-gram) speculative decoding — no drafter model, zero extra RAM — is the right speculative choice for our codegen, not a drafter.** llama-server now ships `--spec-type ngram-*`; for code that **echoes the prompt** (rewriting a component, editing org-mode, repeating identifiers/imports) acceptance is high and the draft is free. Expect **1.3–1.8× decode** on echo-heavy output. ([speculative.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md), [#21453](https://github.com/ggml-org/llama.cpp/issues/21453))
3. **Drafter model = Granite-4.0-350M (vocab-verified compatible).** If prompt-lookup underdelivers on *novel* code, use the **`unsloth/granite-4.0-350m-GGUF` Q4_K_M** drafter — `vocab_size 100352`, identical to granite-4.1-3b (100352) and the whole nano family. Realistic **1.4–2× decode** on code, but on 2 physical cores the drafter steals compute, so measure net. ([unsloth 350m](https://huggingface.co/unsloth/granite-4.0-350m-GGUF), [config evidence below](#1-speculative-decoding))
4. **Prefill (TTFT) tuning: `-ub 256`, `-b 2048`, `--flash-attn on`, `--threads-batch 4`.** Prefill is compute-bound on AVX2; right physical-batch + flash-attn shaves the *uncached* prefill that caching can't remove (first request, novel suffix). ([server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md))
5. **Threads: keep 4 (SMT helps here), pin + `--mlock`.** We *measured* 4>2 (22 vs 13.7) — SMT hides AVX2 latency on this 2-core box, so the "physical cores only" rule does **not** hold for us. Lock it in, add `--mlock --no-mmap`, and set `--cache-type-k/-v q8_0` to halve KV RAM at ~free quality. Small but free.
6. **Quant: stay Q4_K_M; A/B a runtime-repacked Q4_0 build for decode.** On AVX2 EPYC, Q4_0 with **online repacking** (auto since Q4_0_4_4/8_8 were removed) can lift prompt-processing and give a small decode bump — but it's buggy/uneven on some AVX2 setups. Benchmark, don't assume. IQ/i-quants stay **banned** (slower on AVX2). ([#10757](https://github.com/ggml-org/llama.cpp/issues/10757), [#16479](https://github.com/ggml-org/llama.cpp/issues/16479))

> **Lead answers:** (1) Drafter = **`unsloth/granite-4.0-350m-GGUF` Q4_K_M (vocab 100352 ✓)** — but **try prompt-lookup `--spec-type ngram-simple` first** (free, no RAM). (2) **Biggest practical win = prompt/KV caching of the fixed DSL prefix** (`--cache-prompt` + slot persistence), turning ~36 s of repeat prefill into ~0.

---

## 1. Speculative decoding

### a. The drafter — vocab-verified

**Speculative decoding requires the drafter and target to share an identical tokenizer/vocabulary**;
llama.cpp verifies this at load and refuses a mismatch. ([speculative.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md))
I pulled the actual `config.json` vocab sizes:

| Model | `vocab_size` | arch | role |
|---|---|---|---|
| **granite-4.1-3b-instruct** (target) | **100352** | dense decoder | our target |
| granite-4.0-350m-base | **100352** | `granitemoehybrid`, dense (0 experts) | **drafter ✓** |
| granite-4.0-h-350m-base | **100352** | hybrid Mamba2 | drafter ✓ (vocab) |
| granite-4.0-1b-base | **100352** | dense decoder | drafter ✓ |

Sources: granite-4.0-350m-base `config.json` (`vocab_size 100352`), granite-4.0-1b-base (`100352`),
granite-4.0-h-350m-base (`100352`) — all fetched from
[huggingface.co/ibm-granite/granite-4.0-350m-base](https://huggingface.co/ibm-granite/granite-4.0-350m-base),
[granite-4.0-1b-base](https://huggingface.co/ibm-granite/granite-4.0-1b-base),
[granite-4.0-h-350m-base](https://huggingface.co/ibm-granite/granite-4.0-h-350m-base). The whole
Granite-4.0-nano family (350M / H-350M / 1B / H-1B) and granite-4.1-3b **all carry vocab 100352** —
a real, sub-3B, GGUF, vocab-compatible drafter exists. ✅

**Pick the dense 350M, not the H (hybrid):** the dense `granite-4.0-350m` decodes through llama.cpp's
mature attention kernels; the H-350M's Mamba2 CPU kernels are less tuned and a drafter must be *fast*.
**Exact repo + file:**
[`unsloth/granite-4.0-350m-GGUF`](https://huggingface.co/unsloth/granite-4.0-350m-GGUF) →
`granite-4.0-350m-Q4_K_M.gguf` (also IBM-official
[`ibm-granite/granite-4.0-350m-GGUF`](https://huggingface.co/ibm-granite/granite-4.0-350m-GGUF)).

**Verify vocab match yourself before trusting it** (don't rely on the table — confirm on the actual GGUFs):

```bash
# vocab line printed by llama.cpp at load; must match between target and drafter
llama-server -m granite-4.1-3b-instruct-Q4_K_M.gguf --verbose 2>&1 | grep -i 'n_vocab\|vocab type\|tokenizer'
llama-server -m granite-4.0-350m-Q4_K_M.gguf       --verbose 2>&1 | grep -i 'n_vocab\|vocab type\|tokenizer'
# or, model-agnostic:
python3 -c "from transformers import AutoTokenizer as T; \
print(len(T.from_pretrained('ibm-granite/granite-4.1-3b-instruct'))); \
print(len(T.from_pretrained('ibm-granite/granite-4.0-350m')))"   # both 100352
```

### b. Model-free alternative — prompt-lookup / n-gram (recommended FIRST for codegen)

Modern llama-server has speculative decoding built in via `--spec-type`, with **n-gram modes that need
no drafter model at all**: `ngram-simple`, `ngram-map-k`, `ngram-map-k4v`, `ngram-mod`, `ngram-cache`.
([server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md),
[speculative.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md)) These draft by
matching the recent output against n-grams in the prompt/context and proposing the continuation —
**zero extra RAM, zero extra model load.** (The old standalone `llama-lookup` /
`--lookup-cache-static/-dynamic` path still exists, but `--spec-type ngram-*` is the in-server way.)

**Why this beats a drafter for OUR case:** we have **2 physical cores**. A 350M drafter *competes for
those same cores* on every draft step. n-gram drafting is nearly free, and our output is **echo-heavy**
— rewriting a `wb-*` component repeats imports, tag names, attribute lists, CSS tokens, org headings.
For that distribution, prompt-lookup acceptance is high and the cost is ~nil. **Rank: try `ngram-simple`
first; only reach for the 350M drafter if n-gram acceptance is low on *novel* generation.**

```bash
# Prompt-lookup, no drafter model, no extra RAM:
llama-server -m granite-4.1-3b-instruct-Q4_K_M.gguf \
  --spec-type ngram-simple \
  --spec-draft-n-max 8 --spec-draft-n-min 1 \
  -t 4 -tb 4 -c 8192 --mlock --no-mmap \
  --cache-type-k q8_0 --cache-type-v q8_0 -fa on \
  --host 0.0.0.0 --port 8080
```

### c. Drafter setup + exact flags to sweep

**Flag names changed** — the old `--draft-max`/`--draft-min` are **deprecated/removed**; use the
`--spec-draft-*` family. ([speculative.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md))

| New flag | Old alias | Default | Meaning |
|---|---|---|---|
| `--spec-draft-model` / `-md` | `--model-draft` | — | drafter GGUF path |
| `--spec-type draft-simple` | — | `none` | enable model-drafter mode |
| `--spec-draft-n-max` | `--draft-max` | **3** | max tokens drafted per step (sweep target) |
| `--spec-draft-n-min` | `--draft-min` | 0 | min draft length before verify |
| `--spec-draft-p-min` | `--draft-p-min` | 0.00 | min draft prob to accept (greedy) |
| `--spec-draft-p-split` | — | 0.10 | split probability |
| `--spec-draft-threads` | — | = `-t` | **pin drafter to its own threads** |
| `--cache-type-k-draft` / `--cache-type-v-draft` | — | f16 | drafter KV type |
| `--gpu-layers-draft` / `--spec-draft-ngl` | — | auto | **N/A on CPU — ignore** |

```bash
# Drafter (350M) speculative decoding:
llama-server \
  -m  granite-4.1-3b-instruct-Q4_K_M.gguf \
  -md granite-4.0-350m-Q4_K_M.gguf \
  --spec-type draft-simple \
  --spec-draft-n-max 8 --spec-draft-n-min 1 --spec-draft-p-min 0.5 \
  --cache-type-k-draft q8_0 --cache-type-v-draft q8_0 \
  -t 4 -tb 4 -c 8192 --mlock --no-mmap -fa on \
  --cache-type-k q8_0 --cache-type-v q8_0 \
  --host 0.0.0.0 --port 8080
```

**What to sweep:** `--spec-draft-n-max` over **{4, 8, 12, 16}** (default 3 is conservative; code tolerates
deeper drafts), and `--spec-draft-p-min` over **{0.0, 0.5, 0.75}** (higher p-min cuts wasted verifies —
0.75 reportedly lifts effective acceptance up to ~7 tokens). ([DataCamp MTP tutorial](https://www.datacamp.com/tutorial/multi-token-prediction-llama-cpp))

**Reading acceptance rate:** llama.cpp prints e.g. `draft acceptance rate = 0.57576 (171 accepted / 297
generated)` at the end of a run / per request. ([speculative.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md))
Heuristic: **acceptance ≥ ~0.6 ⇒ net win; ≤ ~0.4 ⇒ likely a wash or loss** (verify + wasted-draft
overhead eats it). On a 2-physical-core box this bar is *higher* than on a GPU because the drafter
isn't free.

**Realistic speedup for OUR box:** published code-gen pairs hit **1.8–2.5×** at n-max 5–10 (e.g. Llama
3.1-8B drafted by 3.2-1B → 1.83× at draft=5; coding peaked 2.5× at draft=10), and the llama.cpp CPU
research track targets **1.5–3×** on CPU where *sequential decode is the bottleneck* —
exactly our regime. ([#21453](https://github.com/ggml-org/llama.cpp/issues/21453),
[speculative.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md)) But those are
8B-target ratios; with a **3B target and only 2 cores**, expect a more modest **~1.4–1.8×** on
accepted-heavy code, and possibly **~1.0×** on prose-y or novel output. Measure before committing.

---

## 2. Unsloth — fine-tuning only, NOT an inference engine

**Correct the expectation: Unsloth gives us nothing at serving time.** It is a **QLoRA/LoRA fine-tuning
accelerator** (custom Triton kernels + memory tricks); inference still runs on llama.cpp. It helps the
**fine-tune step**, not tok/s on the box. ([Unsloth Granite 4.0 docs](https://unsloth.ai/docs/models/tutorials/ibm-granite-4.0))

What it *does* give the QLoRA pass:
- **~2× faster training, ~70–80% less VRAM** vs vanilla HF QLoRA — lets the granite-4.1-3b fine-tune fit a single modest GPU.
- **A clean GGUF export path**: Unsloth's `save_pretrained_gguf` / `save_pretrained_merged` merges the LoRA into the base and exports GGUF in one step, then you `llama-quantize` to Q4_K_M.
- Unsloth ships the **Granite GGUFs we're already using as drafter/target** ([`unsloth/granite-4.0-350m-GGUF`](https://huggingface.co/unsloth/granite-4.0-350m-GGUF), [`unsloth/granite-4.1-3b-GGUF`](https://huggingface.co/unsloth/granite-4.1-3b-GGUF)).

**Inference-speed gains from Unsloth on this box: none.** Use it for the QLoRA + export, then serve the
exported GGUF under the llama.cpp tuning in this doc. (Fine-tuning interaction worth keeping: a
drafter fine-tuned on the *same* Workbooks/DSL corpus raises spec-decode acceptance — if you QLoRA the
3B, also QLoRA or at least co-train the 350M drafter to match the distribution.)

---

## 3. Other accelerators — what's actually merged vs research

| Technique | In llama.cpp today? | Use for us? |
|---|---|---|
| **Prompt caching (`--cache-prompt`)** | ✅ merged, default ON | **YES — #1 win** (§5) |
| **Slot save/restore (`/slots`, `--slot-save-path`)** | ✅ merged | **YES** — persist the DSL-prefix KV across restarts (§5) |
| **`--cache-reuse N` (KV shifting)** | ✅ merged | YES — reuse a cached prefix even when a few early tokens differ |
| **Context shift (`--context-shift`)** | ✅ merged (default OFF) | optional — only for runaway-length generation; off for us |
| **n-gram / prompt-lookup (`--spec-type ngram-*`)** | ✅ merged | **YES — try first** (§1b) |
| **Drafter speculative (`--spec-type draft-simple`)** | ✅ merged | YES if n-gram weak (§1c) |
| **EAGLE-3 (`--spec-type draft-eagle3`)** | ✅ flag present | **No** — needs an EAGLE head trained for Granite; none published. Skip. |
| **MTP (`--spec-type draft-mtp`)** | ✅ flag present | **No** — needs MTP weights; Granite 4.x ships none. Skip. |
| **Medusa / lookahead / self-speculative** | research / not first-class | No — not a usable merged path for Granite. |

Source for the merged flag set: [server README `--spec-type` options](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
(`draft-simple, draft-eagle3, draft-mtp, ngram-simple, ngram-map-k, ngram-map-k4v, ngram-mod, ngram-cache`).
**Bottom line:** the two usable levers are **prompt caching** and **n-gram/350M speculative** — EAGLE/Medusa/MTP
all require Granite-specific trained heads that don't exist, so they're dead ends for now.

---

## 4. Build + runtime tuning for a 2-core SMT AVX2 box

**Build (CPU, AVX2, native):**
```bash
cmake -B build -DGGML_NATIVE=ON -DCMAKE_BUILD_TYPE=Release \
  -DGGML_OPENMP=ON                       # OpenMP threadpool
cmake --build build -j --config Release
# GGML_NATIVE=ON auto-enables AVX2/FMA/F16C for EPYC-Milan; no AVX-512 on this CPU.
```

**Threads — our measurement overrides the textbook rule.** Conventional advice is "threads = physical
cores" ([#21112](https://github.com/ggml-org/llama.cpp/discussions/21112)), but we **measured 4 threads
(22 t/s) beating 2 (13.7)** — SMT hides AVX2 FMA latency on these 2 cores, so **`-t 4` is correct for us.**
Lock it; re-sweep only after any build change:
```bash
-t 4 -tb 4         # generation + batch/prefill both 4
```

**Prefill / TTFT (our 42 tok/s prefill is the uncached cost):**
- `-b 2048` (logical batch, default 2048) — leave high.
- **`-ub 256`** (physical ubatch, default 512) — on a 2-core/8GB box a *smaller* ubatch often improves
  prefill throughput and cuts peak RAM; sweep `-ub {128, 256, 512}` and keep the TTFT winner.
- **`-fa on`** (flash attention) — speeds attention prefill+decode and is *required* for KV-cache
  quant. Granite-4.1-3b is **dense**, so flash-attn applies to all layers (unlike the 4.0 hybrids).
  ([server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md))

**Memory / stability on the 8 GB box:**
```bash
--mlock --no-mmap                 # pin weights, kill page-fault stalls (model is only ~2.6 GB)
--cache-type-k q8_0 --cache-type-v q8_0   # halve KV RAM, ~free quality; needs -fa on
```
**Do NOT use `q4_0` KV** — at long context the in-attention dequant can be dramatically slower on CPU,
and quality dips; `q8_0` is the safe choice (per GRANITE-EFFICIENCY.md's cited NVIDIA/smcleod benches).

**Repacked quants for prefill:** `Q4_0_4_4`/`Q4_0_8_8` were **removed**; download a plain **Q4_0** GGUF
and llama.cpp does **online repacking** automatically on AVX2, which historically gave a nice
prompt-processing bump and a small decode bump on EPYC. ([#10757](https://github.com/ggml-org/llama.cpp/issues/10757))
**Caveat:** there are open AVX2 repack bugs (segfaults, server-path gaps) — treat it as an A/B, not a default. ([#16479](https://github.com/ggml-org/llama.cpp/issues/16479))

**ik_llama.cpp** (ikawrakow fork) can beat upstream on some CPU quants via repacked row-interleaved
formats, but it's less maintained and a separate build — **one benchmark, not a migration** (same verdict as the prior doc).

**NUMA:** single-socket dedicated box ⇒ skip NUMA flags.

---

## 5. Prompt / KV caching for our workload — the biggest TTFT win

Our pattern: **the same long system + DSL-context prefix on most requests**, only the user task /
target component changes. That prefix is pure prefill cost — at **42 tok/s**, a **1,500-token preamble =
~36 s** of prefill *if paid every request*. It shouldn't be.

**`--cache-prompt` is ON by default** and per-request `cache_prompt: true` is the default in
`/completion`: *"the common prefix does not have to be re-processed, only the suffix that differs
between requests."* ([server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md))
Because we're **single-stream, one persistent slot**, consecutive requests that share the DSL prefix
hit the cached KV and **pay prefill only on the changed tail** → TTFT collapses from ~hundreds of ms /
tens of seconds to **~the suffix length only**.

Make it bulletproof:
```bash
llama-server -m granite-4.1-3b-instruct-Q4_K_M.gguf \
  --cache-prompt \
  --slot-save-path /var/cache/llama/slots \   # persist the prefix KV across restarts
  --cache-reuse 256 \                          # reuse prefix even if early tokens drift (KV shift)
  --keep -1 \                                  # keep the whole initial prompt on overflow
  -c 8192 -t 4 -tb 4 --mlock --no-mmap -fa on \
  --cache-type-k q8_0 --cache-type-v q8_0
```

**Warm + persist the DSL prefix once**, so even a server restart starts hot:
```bash
# 1. Send the canonical DSL preamble once to populate slot 0:
curl -s localhost:8080/completion -d '{"prompt":"<SYSTEM+DSL PREAMBLE>","n_predict":1,"cache_prompt":true}'
# 2. Persist that slot's KV to disk:
curl -s "localhost:8080/slots/0?action=save" -d '{"filename":"dsl-prefix.bin"}'
# 3. On boot, restore it instead of re-prefilling:
curl -s "localhost:8080/slots/0?action=restore" -d '{"filename":"dsl-prefix.bin"}'
```

**Win:** for the steady-state "another component, same DSL" request, **prefill on the shared prefix → 0**,
so TTFT is dominated only by the short novel suffix + first-token decode. This is the **single biggest
practical TTFT lever** and is orthogonal to (stacks with) speculative decoding. Keep the prefix **byte-
stable** (same ordering, no per-request timestamps in the preamble) or the cache misses.

---

## 6. Quant revisit — Q4_K_M vs Q4_0 vs i-quants on AVX2

- **Q4_K_M (current): keep as the default.** It's the codegen sweet spot at ~4.8 bpw; 22 t/s decode is our baseline.
- **Q4_0 with online repacking: worth a decode A/B.** Simpler dequant + AVX2 row-interleave repacking
  has historically lifted prompt-processing and nudged decode up on EPYC-class AVX2; download a plain
  Q4_0 GGUF (no `_4_4`/`_8_8` suffix — those are removed) and it repacks automatically. **But** quality
  drops measurably for code vs Q4_K_M, and there are open AVX2 repack bugs — so this is a *measured*
  tradeoff, only adopt if the decode gain is real and quality holds post-QLoRA. ([#10757](https://github.com/ggml-org/llama.cpp/issues/10757), [#16479](https://github.com/ggml-org/llama.cpp/issues/16479))
- **IQ / i-quants (IQ4_XS etc.): banned on this box.** They decode *slower* on AVX2 (no inline dequant
  acceleration) and we don't need the size saving — pure tok/s loss (per GRANITE-EFFICIENCY.md's cited ik_llama/kaitchup benches).
- **Q5_K_M / Q6_K:** quality insurance only, ~10–25% slower — reserve for the case where QLoRA'd Q4_K_M regresses DSL correctness.

---

## Ordered experiment plan (do in this order; expected deltas)

| # | Change | Command delta | Expected | Measure |
|---|---|---|---|---|
| 0 | **Lock baseline knobs** | `-t 4 -tb 4 --mlock --no-mmap -fa on --cache-type-k/v q8_0` | +5–15% decode, RAM↓, stable | decode tok/s, RSS |
| 1 | **Prompt caching of DSL prefix** | `--cache-prompt --slot-save-path … --cache-reuse 256 --keep -1` + warm/save slot | **TTFT 10–100×** on repeat reqs | TTFT cold vs warm |
| 2 | **Prefill batch sweep** | `-ub {128,256,512}` | TTFT 1.1–1.4× on novel suffix | prefill tok/s, TTFT |
| 3 | **Prompt-lookup speculative** | `--spec-type ngram-simple --spec-draft-n-max 8` | **decode 1.3–1.8×** on echo-heavy code, 0 RAM | decode tok/s, accept rate |
| 4 | **350M drafter speculative** | `-md granite-4.0-350m-Q4_K_M.gguf --spec-type draft-simple`, sweep `n-max{4,8,12,16}`, `p-min{0,0.5,0.75}` | **decode 1.4–1.8×** if accept ≥0.6; possibly ~1.0× | accept rate, **net** tok/s, RSS |
| 5 | **Q4_0 repack A/B** | swap to Q4_0 GGUF | decode +0–15% or regression | decode tok/s, quality eval |

Run 3 and 4 as a fork: **adopt whichever wins on net decode tok/s.** Stack the winner with 0–2.
Re-run the full QLoRA'd model through 0–5 after fine-tuning (quant fidelity + acceptance shift).

## What to measure (every run)

- **Decode tok/s** (steady-state generation) and **prefill tok/s** separately — llama-server reports both.
- **TTFT**: cold (empty slot) vs **warm** (DSL prefix cached) — the caching win only shows in the warm number.
- **Draft acceptance rate**: the `draft acceptance rate = X (a accepted / g generated)` line; gate spec-decode on ≥~0.6.
- **RSS** (`ps -o rss`): drafter adds ~250–350 MB; confirm we stay under 8 GB with KV.
- **Quality**: a fixed held-out set of "emit a `wb-*` Lit component / org-mode block" prompts, eyeballed
  or LLM-judged — guard every speed change (Q4_0, deep drafts) against silent codegen regressions.

---

### Sources
- llama.cpp speculative decoding docs: <https://github.com/ggml-org/llama.cpp/blob/master/docs/speculative.md>
- llama.cpp server README (caching, slots, batch, spec-type, KV flags): <https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md>
- CPU speculative-decoding research issue #21453: <https://github.com/ggml-org/llama.cpp/issues/21453>
- Q4_0 runtime-repacking (Q4_0_4_4 removed): <https://github.com/ggml-org/llama.cpp/issues/10757>
- AVX2 Q4_0 repack segfault: <https://github.com/ggml-org/llama.cpp/issues/16479>
- Granite-4.0-350m GGUF (drafter): <https://huggingface.co/unsloth/granite-4.0-350m-GGUF> · <https://huggingface.co/ibm-granite/granite-4.0-350m-GGUF>
- Granite-4.1-3b GGUF (target): <https://huggingface.co/unsloth/granite-4.1-3b-GGUF>
- Granite vocab configs: <https://huggingface.co/ibm-granite/granite-4.0-350m-base> · <https://huggingface.co/ibm-granite/granite-4.0-1b-base> · <https://huggingface.co/ibm-granite/granite-4.0-h-350m-base>
- Granite 4.0 nano models repo: <https://github.com/ibm-granite/granite-4.0-nano-language-models>
- Unsloth Granite 4.0 (fine-tune + GGUF export): <https://unsloth.ai/docs/models/tutorials/ibm-granite-4.0>
- Speculative flags / n-max sweep tutorial: <https://www.datacamp.com/tutorial/multi-token-prediction-llama-cpp>
- Thread-count discussion: <https://github.com/ggml-org/llama.cpp/discussions/21112>
