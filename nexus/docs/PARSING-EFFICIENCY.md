# Untrusted-HTML parsing efficiency — ranked options for hundreds of concurrent scrapers on 1GB hosts

**Scope.** We extract only: readable main text, the link graph (href + anchor, absolute),
title, optional HTML→markdown. We do **not** need a full DOM or a layout/render. Input is
**attacker-controlled web HTML** — memory-safety on the trusted BEAM is a hard constraint.

**Substrates allowed** (isolation thesis): (a) wasm in wasmtime, (b) pure Elixir/BEAM.
Native C NIFs that parse hostile input *in the trusted VM* (Floki's `fast_html`/Lexbor backend,
`myhtmlex`) are a **host-compromise risk** — a parser bug segfaults or owns the whole runtime
with no sandbox — and are rejected for this workload regardless of speed.

All numbers below are **measured** on this machine (Erlang/OTP 28, JIT; M-series mac), with a
peak-heap sampler (a watcher process polling `process_info(:memory)`) — i.e. the **transient
working set during the parse**, which is the spike that caps concurrency. Benchmark scripts:
`/tmp/bench*.exs`, `/tmp/conc.exs`, `/tmp/pf.exs`. Test pages: real Wikipedia articles
235KB (Erlang), 809KB (Mathematics), 1.4MB (India — worst case).

---

## 1. Where the current cost actually is (profiling `Nexus.Browse.Extract`)

Decomposing the current `Floki.parse_document → find → traverse_and_update → text` pipeline on
the **India 1.4MB** page (`/tmp/bench2.exs`, peak-heap sampled):

| Stage | Wall | Peak heap |
|---|---|---|
| `parse_document` (mochiweb tree build) | **263 ms** | **14.9 MB** |
| `find "a[href]"` (traversal) | 25 ms | (no new peak) |
| `find "body"` | 8 ms | (no new peak) |
| `traverse_and_update` strip | 8 ms | (no new peak) |
| `Floki.text` whole doc | 4 ms | (no new peak) |

**The tree build is the entire cost — ~90% of wall, 100% of the memory ceiling.** The "4
traversals" are nearly free: they walk the already-built tree and add no peak. **Collapsing 4
traversals → 1 saves ~40ms of CPU and ZERO memory.** So tuning the traversals is the wrong lever;
the lever is *not building the tree at all*.

Confirmed: Floki here uses the **mochiweb Erlang tokenizer+tree-builder** (`floki_mochi_html`, no
NIF — pure BEAM, memory-safe). Good safety floor; the cost is the materialized tree.

---

## 2. Pure-Elixir streaming (SAX) — survey + prototype

**Floki's spec `HTML.Tokenizer` (pure Elixir) is a TRAP — do not use it.** Benchmarked
(`/tmp/bench.exs`): it is **2–3× slower AND 6–10× more memory** than the full Floki parse
(India: **77 MB / 520ms** vs 15 MB / 263ms). Its tokens are deeply-nested charlists-of-charlists
that aren't even valid iodata; flattening them per-token is pathological. Rejected.

**Saxy** is XML-only and will not parse real-world (non-wellformed) HTML. Rejected.

**The winner: stream the mochiweb tokenizer directly.** `floki_mochi_html` exports
`tokens/1` — the *efficient* Erlang tokenizer, emitting clean `{:start_tag, name, attrs, self}`
/ `{:end_tag, name}` / `{:data, bin, ws}` tuples — **without building a tree**. I prototyped a
single-pass fold that maintains a tiny state (`skip`-depth for boilerplate tags, `in_a` for anchor
capture) and emits links + text + title in **one pass, O(state) memory** (`/tmp/bench3.exs`):

| Page | Floki full (parse+extract) | **STREAM mochi (1 pass)** | Win |
|---|---|---|---|
| Erlang 235KB | 11 ms / 5.0 MB | **4.7 ms / 1.9 MB** | 2.4× faster, 2.7× less mem |
| Math 809KB | 100 ms / 6.4 MB | **58 ms / 9.2 MB** | 1.7× faster |
| India 1.4MB | 263 ms / 14.9 MB | **117 ms / 10.7 MB** | **2.2× faster, 28% less peak** |

Results are correct (links/anchor-text/main-text all captured; title trivially added). This is the
biggest single, safe, zero-new-dependency win. It uses the **same memory-safe pure-BEAM tokenizer
already shipped inside Floki** — no new attack surface.

---

## 3. Pre-filtering before tokenizing

Strip `<script>/<style>/<svg>/<noscript>/<template>` + comments via regex before the tokenizer
(`/tmp/pf.exs`):

- **Cost is trivial:** 1–4.5 ms, ~0 MB (binary sub-references).
- **Win is page-dependent.** Wikipedia is script-light (filtered = 90–97% of original) → little
  gain, and the binary-regex on a 1.4MB input even *raised* peak slightly (sub-binary churn). On
  **script-heavy pages** (SPA shells, marketing sites with large inline JS/JSON-LD/analytics) the
  shrink — and the win — is far larger.
- **Fragility:** regex-on-HTML is not robust (nested/commented/malformed tags). Acceptable here
  because it's a *best-effort shrink before a real tokenizer*, never the parse itself — a missed
  block just gets handled by the tokenizer + `skip`-depth as today.

**Verdict:** apply prefilter **conditionally** — only when inline `<script>`/`<style>` exceeds a
byte threshold (cheap to measure). Don't pay the regex pass on already-lean pages.

---

## 4. Faster native backends (honest safety verdict)

Floki + `fast_html` (Lexbor NIF) / `selectolax`-style native parsers are ~5–10× faster than
mochiweb. **Rejected for this workload.** They run a C HTML parser **inside the trusted BEAM** on
attacker-controlled bytes: one parser bug = segfault or RCE that **owns the entire runtime**, with
no sandbox boundary. The runtime *does* ship trusted NIFs (`wasmex`, `exqlite`) — but those never
parse hostile web input; the threat model is categorically different. For a fleet of hundreds of
scrapers eating arbitrary internet HTML, the blast radius is the whole host. **The streaming
pure-BEAM path (§2) already recovers ~2× of the speed with zero safety cost** — that's the right
trade for this workload. (A native parser would be defensible only behind the wasm sandbox — §5.)

---

## 5. Parser-to-WASM (Lexbor / lol-html / html5ever in wasmtime)

Feasible via our compiler lane and aligned with the thesis (sandboxed like `Nexus.Browse.Blitz`).
**lol-html** (Cloudflare's streaming Rust rewriter) is the ideal candidate: streaming, O(1)
memory, Rust-memory-safe, small. A dedicated parser module would be **~1–3 MB** (vs the 9.6 MB
Blitz render — no CSS/layout/paint engine).

**But the per-call model kills it for the common page.** Measured (`/tmp/wo.exs`): a wasmtime
invocation of `render_text.wasm` on a *trivial* page costs **~139 ms** — the fork+exec + WASI +
module-load floor. That floor **alone exceeds the entire BEAM streaming parse** (4–117 ms) for
typical pages. AOT precompile (`Nexus.Wasm.Aot`) trims module-load but not the OS-process spin-up,
and the `:render` gate (slot-limited to avoid fork-bombing wasmtime into OOM) makes it a
*bounded* lane — exactly what we do **not** want for "hundreds of concurrent" cheap reads.

**Verdict:** wasm-sandboxed parsing is the **correct** answer *if* we ever need native-grade speed
on hostile input — it gets native speed without the trusted-VM risk. But for *this* extract
workload, pure-BEAM streaming is faster net (no sandbox/process overhead) and simpler. Keep the
wasm parser in reserve as a future in-process (Wasmex-resident, not CLI-fork) component if a
specific heavy-parse need appears — the CLI-fork shape benchmarked here is the wrong shape for it.

---

## Ranked recommendation

| Rank | Option | India 1.4MB | Safety | Files to change | Effort/Risk |
|---|---|---|---|---|---|
| **1** | **Streaming mochiweb fold (1 pass)** | 117ms / 10.7MB | ✅ pure BEAM, safe | `nexus/lib/browse/extract.ex` | **Low / Low** |
| 2 | + conditional prefilter (script-heavy only) | +0 on lean, big win on SPA shells | ✅ best-effort, safe | same file | Low / Low |
| 3 | Status quo (Floki full) | 263ms / 14.9MB | ✅ safe | — | none |
| 4 | wasm lol-html (Wasmex-resident, future) | ~native + sandbox overhead | ✅ sandboxed | new `priv/*.wasm` + provider | High / Med |
| ✗ | Native Lexbor NIF in BEAM | ~30ms | ❌ host-compromise risk | — | rejected |
| ✗ | Floki spec `HTML.Tokenizer` | 520ms / 77MB | ✅ safe but awful | — | rejected (slower+heavier) |

### Expected lift to "concurrent parses per 1GB"

Concurrency-sampled on the **1.4MB worst case** (`/tmp/conc.exs`, peak BEAM mem over baseline):

| N concurrent | Floki full peak | STREAM peak | per-parse (stream) |
|---|---|---|---|
| 20 | 387 MB | 365 MB | 18.2 MB |
| 50 | 663 MB | 565 MB | 11.3 MB |
| 100 | 1196 MB | **958 MB** | 9.6 MB |
| 200 | 2077 MB | 1758 MB | 8.8 MB |

Streaming cuts per-parse transient ~**15–28%**. On a 1GB host (worst-case 1.4MB pages) that moves
the safe ceiling from ~**50–60** to ~**80–100** concurrent parses; on typical 200–400KB pages the
per-parse working set is ~2–4 MB, so a 1GB host comfortably runs **150–300+** concurrent streaming
parses. The CPU halving also clears each parse ~2× faster, raising **throughput** independently of
the memory ceiling. Adding conditional prefilter on script-heavy pages widens the gap further where
it matters most (real-world non-Wikipedia pages carry far more `<script>`).

---

## Recommended direction + build sequence

**Rewrite `Nexus.Browse.Extract.read/2` around a single streaming fold over
`:floki_mochi_html.tokens/1`** — never materialize the tree. Keep the exact public contract
(`%{title, text, markdown, links, thin?}`) and the Blitz escalation on `thin?`.

1. **Single-pass extractor.** Fold tokens into `{title, links, text, markdown}` with a `skip`-depth
   counter for `@drop` boilerplate tags and an `in_a` capture for anchor text. Resolve hrefs
   absolute + dedup at emit time (as today). Markdown: accumulate a lightweight tag-stack and emit
   the same block/inline rules currently in `md_node/1` during the fold (headings, lists, pre,
   strong/em/code) — no second tree walk. ~1 file, contract-preserving.
2. **Conditional prefilter.** Before tokenizing, if inline `<script>+<style>` bytes exceed a
   threshold (cheap `:binary.matches` count), run the regex strip; otherwise skip it.
3. **Guardrails.** Wrap the fold in the existing never-raise contract; cap accumulated text/links
   to a sane max to bound a pathological adversarial page.
4. **Keep wasm parsing in reserve.** Do **not** build the lol-html wasm now; revisit only as a
   Wasmex-*resident* (not CLI-fork) component if a future heavy-parse need appears. Native NIF
   parsers stay off the table for hostile input.

Net: ~2× faster, ~15–28% lower per-parse memory ceiling, no new dependency, no new attack surface,
same isolation posture — the cheap read rung gets cheaper exactly where the fleet lives.
