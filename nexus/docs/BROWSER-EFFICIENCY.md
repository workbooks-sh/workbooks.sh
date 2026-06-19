# Browser efficiency — making the in-wasm render rung scale to hundreds of concurrent scraping agents

Scope: the **wasm-render rung** beneath `Nexus.Browse.Blitz` (the Floki cheap-read rung is a
teammate's, assumed to exist and to be the default). Hard constraints: only two execution
substrates — wasm-in-wasmtime and Elixir/BEAM. No Chromium, no native exec outside the sandbox.
Isolation = **one Engine + one cached Module, MANY Stores/instances** (each its own private linear
memory); never two pages in one store.

Grounding: `lib/browse/blitz.ex`, `lib/wasm/{aot,gate}.ex`, `lib/js_engine.ex`, `lib/js_dom.ex`,
`lib/dock.ex`, `lib/compile/store.ex`, the Blitz source at
`wasm-video/crates/wavelet-render-core/` (Cargo.toml + `src/bin/{render_text,render_js,render_page,measure}.rs`),
and `vendor/wasmex/`.

---

## How the current path actually works (measured/read, not assumed)

`Blitz.run/4` (`lib/browse/blitz.ex:198`) is the choke point. **Every** render mode:

1. mkdir a throwaway tmp dir, writes `page.html`,
2. `Nexus.Wasm.Aot.resolve/1` swaps the `.wasm` for a precompiled `.cwasm` (`--allow-precompiled`),
3. builds a shell string: `wasmtime run <flags> --dir tmp::/work <exec> <argv>` wrapped in a
   `sleep N; kill -9` watchdog,
4. runs it as **one `System.cmd("sh", …)` OS process** under a `Nexus.Wasm.Gate` `:render` slot,
5. reads stdout (text modes) or `out.png` (screenshot), `rm_rf` the dir.

Module per mode (`blitz.ex:204`):

| mode          | module            | size  | engine inside                         |
|---------------|-------------------|-------|---------------------------------------|
| `:text`       | `render_text.wasm`| 9.6MB | Blitz CSS-only (no JS)                |
| `:text_js`    | `render_js.wasm`  | 16MB  | Blitz + **Boa** (pure-Rust JS, linked in) |
| `:measure`    | `measure.wasm`    | ~9.6MB| Blitz layout only (emits boxes)      |
| `:screenshot` | `render_page.wasm`| 18MB  | Blitz + Vello-CPU paint + Boa        |

Separately, the **JS-DOM rung** (`Nexus.JsDom` → `Nexus.JsEngine`) runs **StarlingMonkey**
(`eval-host.wasm`, 11MB) — but **NOT** as a subprocess. `js_engine.ex:17` already runs it
**in-BEAM via `Wasmex.Components.start_link`**. So the codebase already has a working in-BEAM wasm
path; the Blitz modules simply never adopted it.

### Escalation cost (the `:auto` engine, `blitz.ex:51`)

The default `render/2` uses `:boa` (`blitz.ex:30`), and `render_html_boa` (`blitz.ex:85`) **runs
`render_js.wasm` (16MB, Boa) FIRST**, then falls back to `render_text.wasm` only on empty output.
The `:auto` ladder is smarter (fast `render_html_boa`… but that already starts at Boa). Findings:

- **The 16MB Boa module is the default first hop even for plain-SSR pages.** The moduledoc
  (`blitz.ex:37`) says "render fast first," but `render_html_boa` calls `:text_js` (Boa) first and
  only drops to `:text` (CSS-only) on empty output — Boa runs on the common path. For pure-SSR
  pages Boa is pure waste: a bigger module to JIT/instantiate, a JS engine spun up to run nothing
  that changes the text. **This is wasted escalation on the hot path.**
- The `:auto` ladder (rungs 1→2→3, each gated on the prior being thin, `blitz.ex:51-69`) is the
  *correct* shape, but it is not the default and rung 1 (`render_html_boa`) is itself Boa-first.
- `measure.wasm` only fires on the geometry rung (rare).
- StarlingMonkey (`eval-host.wasm`, 11MB) only loads on `engine: :jsdom`/geometry — correctly gated.

**So today, a "hundreds of SSR pages" scrape pays: a 16MB-module subprocess + Boa spin-up per page,
when a 9.6MB CSS-only subprocess (or, better, an in-BEAM warm instance) would do.**

### The dominant cost is process model, not module size

The AOT cache already removed the per-call Cranelift compile (0.24s/121MB → 0.14s/47MB). What
remains per render is: **fork `sh` → fork `wasmtime` → mmap the `.cwasm` → fresh WASI store → run →
tear down**, ×N processes, capped by `Nexus.Wasm.Gate` to ~render-concurrency (≈15 on 1GB). The
marginal ~60MB RSS/render and the fork/teardown latency are process-model costs, not module-content
costs. **The single biggest lever is to stop forking `wasmtime` and run renders in-BEAM via Wasmex,
sharing one Engine + one cached Module across a warm instance pool** — exactly what `JsEngine`
already does for StarlingMonkey.

### Caching: there is none on the read path

- `Nexus.Dock.fetch/1` (`dock.ex:35`) does an SSRF-checked `http_get` and returns the body. **No
  cache** — confirmed. Same URL fetched twice = two egress fetches.
- No url→extracted or html-hash→rendered cache anywhere in `blitz.ex`. Every call re-renders from
  scratch even for identical HTML.
- `Nexus.Compile.Store` (`compile/store.ex`) is a content-addressed two-tier (local hot +
  egress-free S3/R2) store **for compiled components** — directly reusable as the substrate for a
  render-output cache (same key=hash, same immutable-blob discipline).

---

## Recommendations, ranked by bang-for-buck

### R1 — In-BEAM warm render pool via Wasmex (replace the subprocess). ★ top lever

**Lever.** Stop `System.cmd("wasmtime", …)` per render. Build a `Nexus.Browse.RenderServer` that, at
boot, creates **one `Wasmex.Engine`** and **one cached `Wasmex.Module`** per render binary
(`render_text`, `render_js`, `render_page`, `measure`), then runs each render as a fresh
`Wasmex.Store`+instance under a `GenServer`-owned pool — the Engine and Module (read-only code) are
shared; each render gets its own Store + linear memory.

**API (exists in vendor/wasmex — verified).**
- `render_text.wasm` etc. are **WASI command modules** (read `/work/page.html`, write stdout). Run
  them in-BEAM with `Wasmex.start_link(%{module: mod, store: store, wasi: %Wasmex.Wasi.WasiOptions{
  preopen: [%PreopenOptions{path: tmpdir, alias: "work"}], stdout: pipe, args: [...]}})` then drive
  the `_start`/exported entry; capture stdout via `Wasmex.Pipe` (`vendor/wasmex/lib/wasmex/wasi/wasi_options.ex:30`,
  `pipe.ex`). Preopen + stdout-pipe is the in-BEAM equivalent of `--dir tmp::/work` + stdout capture —
  **no subprocess, no `sh`, no fork.**
- Share code across instances: compile once with `Wasmex.Module.compile/2` (or load a precompiled
  blob with `Wasmex.Module.unsafe_deserialize/2` / `Wasmex.Engine.precompile_module/2`,
  `module.ex:171/232`, `engine.ex:98`) and instantiate many Stores against that one Module.

**Expected win.** Removes two `fork`s + a `wasmtime` cold mmap per render and the watchdog `sleep`
process. Latency: subprocess spawn + mmap (~tens of ms each) → an in-process instantiate against an
already-resident Module (cheap). Memory: today each render is a *separate OS process* carrying its
own copy of the wasmtime runtime + mapped code; in-BEAM, the runtime and the Module's code are
resident **once** and shared, so marginal cost collapses toward *just the instance's linear memory*.
Plausibly 2–4× more concurrent renders per GB and materially lower p50 latency. This is the lever
that turns "≈15 concurrent on 1GB" into "many tens."

**Files.** New `lib/browse/render_server.ex` (GenServer + pool, modeled on `js_engine.ex`); rewrite
`Blitz.run/4` (`blitz.ex:198-239`) to call it instead of `System.cmd`. Keep `Nexus.Wasm.Gate`
(now gating *instances*, not processes). Keep `Nexus.Wasm.Aot` for the *CLI* lane and reuse its
precompiled blobs via `unsafe_deserialize`. Replace the `sleep/kill` watchdog with epoch
interruption (R4).

**Effort/risk.** Medium-high. Risk: a command module's WASI `_start` semantics under Wasmex (vs the
component path JsEngine uses) need a smoke test; if the render bins are P1 commands, use the
classic `Wasmex.start_link`/`WasiOptions` path (P1), not `Wasmex.Components` (P2). Fallback: keep
the subprocess path behind a flag.

**Isolation.** ✅ Preserved and arguably *clearer*: one shared read-only Engine+Module (OS sharing a
text segment, same argument `aot.ex` already makes), **one fresh Store + private linear memory per
render**. No page content is ever co-resident in one store. This is the canonical "many instances,
one module" model the constraints mandate.

---

### R2 — Make the default render path CSS-first, not Boa-first. ★ cheap, high-leverage

**Lever.** Change the default so the **9.6MB `render_text` (CSS-only)** runs first and Boa
(`render_js`, 16MB) only fires when the CSS result is thin — i.e. make the `:auto` ladder
(`blitz.ex:51`) the default and fix rung 1 to be `:text` not `:text_js`.

**Why.** The moduledoc already argues this ("render fast first; only escalate when thin; never
regress," `blitz.ex:37-49`) and cites benchmarks where Boa returned identical output on SSR pages
(waste) or *regressed* (GitHub 488→1 lines). But the *default engine is `:boa`* (`blitz.ex:30`) and
`render_html_boa` runs `:text_js` first (`blitz.ex:88`). For a scrape that is mostly SSR pages, the
common path currently pays the bigger module + a JS spin-up for nothing.

**Expected win.** On SSR-dominant corpora (most of the web), drops the per-page module from 16MB→9.6MB
and skips Boa entirely on the hot path — less instantiate cost, less working set, lower latency, and
removes the regression risk. Throughput win compounds with R1 (smaller/cheaper warm instances on the
common path). Magnitude depends on SSR:CSR ratio; for a typical scrape, the majority of pages.

**Files.** `blitz.ex`: default `render/2` opts to `engine: :auto`; in `render_html_auto`, make rung 1
`run(:text, …)` (CSS-only) and escalate to Boa/`:jsdom` on thinness. Keep "keep richest, never
regress." ~15 lines.

**Effort/risk.** Low. Risk: a few JS-rendered-but-not-thin pages that Boa would have improved — but
the ladder still escalates on thinness, and the existing `richness` gate already handles "keep
richest." Net safer than today (no Boa regression on the hot path).

**Isolation.** ✅ No change to the execution model.

---

### R3 — Render-output + fetch cache on the content-addressed store. ★ huge for re-scrapes

**Lever.** Two caches keyed by content hash, reusing `Nexus.Compile.Store`'s two-tier (local hot +
egress-free R2) substrate:
- **fetch cache**: `url → {body, etag, ts}` with TTL, in `Nexus.Dock.fetch`.
- **render cache**: `hash(html ++ mode ++ opts) → output` (text or PNG bytes), immutable blob.

**Why.** `Dock.fetch` has no cache (confirmed, `dock.ex:35`); `Blitz` re-renders identical HTML every
call. Hundreds of agents scraping overlapping sites (the same docs page, the same product grid, the
same homepage) re-fetch and re-render the same bytes constantly. A render is the *expensive* step; an
immutable hash→output blob makes a repeat render O(read-blob).

**Expected win.** For any workload with URL/content overlap — exactly the "hundreds of agents on the
web" case — this is potentially the **largest aggregate compute saving**: a cache hit skips egress
*and* the entire wasm render. Even a modest hit rate removes whole renders from the Gate, freeing
slots for cold work. Fleet-wide via R2 (one machine's render serves the fleet, like the compile
store already does).

**Files.** New `lib/browse/cache.ex` (or fold into `Nexus.Compile.Store` as a second namespace):
`get(key)`/`put(key, bytes)` over `compile/store.ex`'s local+remote tiers. Hook `Dock.fetch`
(`dock.ex:35`) for the fetch cache (respect `Cache-Control`/`etag`, TTL default e.g. 15 min). Hook
`Blitz.run/4` to check `hash(html,mode,opts)` before rendering and `put` after. TTL/etag for fetch;
render blobs are immutable (hash includes inputs) so never invalidated.

**Effort/risk.** Medium. Risk: staleness on the fetch side — bound with TTL + `etag` revalidation;
render blobs carry no staleness risk (pure function of inputs). Privacy: scoped — a public-web scrape
cache is fine to share fleet-wide; do **not** cache anything behind tenant credentials (key the cache
only for unauthenticated public fetches, mirroring `Dock`'s SSRF-public stance).

**Isolation.** ✅ Cache is immutable public-web bytes; no tenant linear memory is shared. Keep it to
credential-free fetches to avoid cross-tenant leakage.

---

### R4 — Epoch interruption instead of the `sleep/kill` watchdog (pairs with R1). 

**Lever.** Replace the shell `sleep N; kill -9` watchdog (`blitz.ex:220`) with wasmtime **epoch
interruption** — Wasmex already supports it: `EngineConfig.epoch_interruption: true` +
`store_or_caller_set_fuel`/epoch deadline (`engine_config.ex:31`, `native.ex:93-94`). A runaway page
(huge JS bundle spinning Boa) traps cleanly at the deadline.

**Why.** The watchdog only works because each render is its own killable OS process. Once R1 moves
renders in-BEAM, you need an *in-engine* deadline; epoch interruption is the supported mechanism and
is cheaper than fuel metering. `consume_fuel` is also available if you want deterministic step caps.

**Expected win.** Enables R1 to keep its timeout guarantee without a per-render `sleep` helper process
(today every render spawns an extra watchdog process — R4 deletes that). Robustness for hostile/heavy
pages.

**Files.** `render_server.ex` (R1): build the Engine with `epoch_interruption: true`, run a 1s epoch
ticker (the moduledoc at `engine_config.ex:28` describes exactly this for the broker), set a deadline
per render. Remove the `guarded` shell wrapper from `blitz.ex`.

**Effort/risk.** Low-medium (rides on R1). Risk: needs the epoch ticker wired; pattern already exists
for the serve path.

**Isolation.** ✅ Per-store deadline; no cross-store effect.

---

### R5 — Bounded `StoreLimits` per render instance. 

**Lever.** Set `Wasmex.StoreLimits{memory_size: …, instances: 1, memories: 1, tables: 1}`
(`store_limits.ex`) on each render Store so a pathological page can't grow linear memory unbounded
and OOM the host.

**Expected win.** Converts the current coarse "Gate caps concurrency to fit RAM" into a hard
*per-instance* memory ceiling, so the concurrency math is exact instead of empirical (the Gate sizes
slots; StoreLimits guarantees each slot's max). Lets you raise render-concurrency safely.

**Files.** `render_server.ex` (R1): pass `StoreLimits` to `Wasmex.Store.new/2`. Size from
`<work-deploy>` config alongside the Gate limits.

**Effort/risk.** Low (rides on R1). **Isolation.** ✅ Tightens it.

---

### R6 — Slim the render modules (feature-gate Vello/Boa/fonts). Real but bounded ROI

**Lever.** The modules are big because of what's statically linked (`wavelet-render-core/Cargo.toml`):
- `render_text`/`measure` need **only** `blitz-dom/html/traits` (layout + text walk). They do **not**
  need `anyrender_vello_cpu`, `vello_cpu`, `peniko`, `kurbo`, `png`, `image`, or `boa_engine`. Today
  they're 9.6MB partly from code they never call; cargo dead-strips unused crates per-binary, but the
  *render path itself* (`load_html_with_base` in `src/lib.rs`) may pull paint/Boa via shared
  functions. **Audit `lib.rs` so `render_text`/`measure` link a paint-free, JS-free subset.**
- `render_js` is 16MB because **Boa is statically linked in** (`boa_engine = "0.20"`,
  Cargo.toml) — confirmed; that is the size delta vs `render_text`. (Note: this is Boa, *not*
  StarlingMonkey — StarlingMonkey is the separate `eval-host.wasm`/`JsEngine`.)
- Fonts: Cargo already does `default-features=false` to drop `system_fonts` and bundles one static
  font — good; little left to cut there.
- **Could `render_text` + `render_js` be one module with a flag?** Yes mechanically (one bin, a CLI
  flag selecting "run Boa or not"), but it would make the common-path module *as big as the Boa one*
  (16MB) — the opposite of R2's goal. **Keep them separate**; the split is a feature, not redundancy.

**Expected win.** A genuinely paint-free, Boa-free `render_text`/`measure` could shave a few MB of
module size → faster instantiate + smaller resident code (shared once under R1, so the win is
amortized across all instances, but real for cold-start and for the per-binary `.cwasm`). Bounded:
single-digit-MB, and **once R1 shares the Module fleet-wide the per-render benefit of a smaller module
is small** — module size mostly hits cold-start, not steady-state RSS. So: do it, but rank it below the
process-model and cache levers.

**Files.** `wavelet-render-core/src/lib.rs` (factor a paint/JS-free text path), `Cargo.toml`
(feature-gate `vello_cpu`/`anyrender_vello_cpu`/`png`/`image`/`boa_engine` behind `paint`/`js`
features; build `render_text`/`measure` with neither). Rebuild the `.wasm` + `.cwasm`.

**Effort/risk.** Medium (Rust refactor + rebuild + re-verify byte output). Risk: factoring the shared
render entry without regressing the paint/JS bins.

**Isolation.** ✅ No execution-model change.

---

### R7 — Pooling allocator + CoW memory init. BLOCKED by a Wasmex gap (worth a small extension)

**Lever.** wasmtime's **pooling allocator** pre-reserves a pool of uniformly-sized instance slots and
recycles them, and **copy-on-write memory initialization** maps a module's initial memory image so a
fresh instance starts by sharing read-only pages and only copies on write. For *many short-lived
identical instances* (exactly the render workload) this is the textbook win: near-zero per-instance
allocation cost and shared initial pages.

**Status — BLOCKED.** The vendored wasmtime **is compiled with `pooling-allocator`** (confirmed in
`native/wasmex/target/.../wasmtime-*.json` features list) and CoW is a wasmtime default, **but Wasmex
does not surface either**: `EngineConfig` exposes only `consume_fuel`, `cranelift_opt_level`,
`wasm_backtrace_details`, `memory64`, `wasm_component_model`, `debug_info`, `epoch_interruption`
(`engine_config.ex:22-33`; mirrored in `native/wasmex/src/engine.rs`). There is **no
`allocation_strategy`/`PoolingAllocationConfig`/`memory_init_cow` field**. So today you cannot ask
Wasmex for a pooling allocator.

**Expected win (if unblocked).** Potentially large for R1's "many short-lived instances" pool:
instance create/destroy becomes slot recycle, and CoW makes each instance's initial memory shared
read-only pages — directly attacks the marginal-RSS-per-render number. This is the highest-ceiling
*memory* lever, but it requires a code change to vendor/wasmex.

**Files (the extension).** `native/wasmex/src/engine.rs` (+ `engine_config.ex`,
`engine_config` decode): add `allocation_strategy: :on_demand | :pooling`, a
`PoolingAllocationConfig` (total_memories / max_memory_size / table_elements), and expose
`memory_init_cow` (likely just stop disabling a wasmtime default). Wire into the `wasmtime::Config`
built in `engine.rs`. Then R1's RenderServer builds its Engine with `allocation_strategy: :pooling`
sized to render-concurrency.

**Effort/risk.** Medium (small, well-scoped Rust/NIF change to a vendored dep we already patch — the
memory notes confirm vendored-wasmex/mrustc surgical patches are sanctioned). Risk: pooling config
must be sized ≥ peak concurrent instances or instantiation fails; pair with R5/Gate sizing.

**Isolation.** ✅ Pooling recycles *slots*, not memory *contents* — each instance still gets a zeroed
(or CoW-from-read-only-image) private linear memory; wasmtime guarantees no residual tenant data
across slot reuse. CoW shares only the module's **read-only initial image**, never writable state.
Safe by construction.

---

## What NOT to do (rejected)

- ❌ One shared store/instance servicing multiple pages — serializes work AND leaks tenant data across
  linear-memory; violates the isolation constraint. (Explicitly out of scope.)
- ❌ Merge `render_text` and `render_js` into one module (R6) — makes the common path pay Boa's size.
- ❌ Any native/headless browser — banned.

---

## Recommended build sequence

1. **R2** (CSS-first default) — ~15 lines, immediately cuts the common-path module 16MB→9.6MB and
   removes Boa from the hot path. Ship first; zero infra change.
2. **R3** (fetch + render cache on `Compile.Store`) — biggest aggregate compute win for overlapping
   scrapes; independent of the process-model work, so land it in parallel.
3. **R1** (in-BEAM warm render pool via Wasmex) — the structural lever; model on `JsEngine`. Land
   **R4** (epoch deadline) and **R5** (StoreLimits) *with* it — they replace the watchdog and make the
   memory math exact.
4. **R6** (slim `render_text`/`measure` to paint-free/JS-free) — Rust refactor; do once R1 is proven so
   you measure the real cold-start delta.
5. **R7** (pooling allocator + CoW via a vendor/wasmex extension) — the highest-ceiling memory lever
   but the only one needing a NIF patch; do last, sized against the R1 pool + R5 limits. Honestly, if
   R1+R3 already hit the concurrency target, R7 is optional polish.

Net: R2+R3 are cheap and land now; R1(+R4+R5) is the structural step that makes "hundreds of agents"
real; R6/R7 are diminishing-returns refinements (R7 gated on a small, sanctioned vendor patch).
