# Tier-2 Research: heavy-SPA execution + computer-use for AI agents WITHOUT Chromium/WebKit and WITHOUT Playwright

**Question.** How can we drive full, interactive heavy-SPA web pages (React/Next, multi-MB
bundles) and do computer-use-style agent navigation — *without* a bundled native
Chromium/WebKit and *without* Playwright — ideally inside or adjacent to our
wasmtime sandbox?

**What we already have (do not re-suggest).** An in-wasm renderer = Blitz
(`blitz-dom` + `blitz-html` + Stylo CSS + Taffy layout + Parley text + Vello-CPU
paint), compiled to `wasm32-wasip1`, rendering fetched pages to text + PNG inside
wasmtime. Boa (pure-Rust JS interpreter) is wired to the Blitz DOM and runs
vanilla/imperative JS, mutating the DOM in-wasm. Fetch is host-brokered (no
sockets in wasip1).

**The wall.** Boa cannot run heavy production framework bundles: capacity overflow,
hundreds of missing browser APIs, and — fundamentally — wasm has no JIT, so an
interpreted JS engine is 10–100× slower than a native browser VM.

> Date: 2026-06-18. Branch: `work-html-format`. This is a research doc — no code.
> Every non-obvious claim is sourced; see the per-section Sources and the master
> list at the end. Throughout, "demoed" ≠ "production"; hype is flagged inline.

---

## 0. TL;DR — the honest shape of the answer

1. **No browser engine renders HTML/CSS *and* runs JS interactivity fully inside a
   wasm sandbox today** — not in production, not even as a proven prototype. The
   pieces exist independently (Blitz = layout+paint in wasm but *no JS*;
   StarlingMonkey = real JS in wasm but *no DOM*); **nobody has assembled the
   integrated stack.** Our current Boa+Blitz wiring is already at the frontier of
   what exists publicly.

2. **You don't need paint to drive the web — you need JS + DOM + layout geometry.**
   The literature on computer-use agents is one-sided: a DOM/a11y-tree agent that
   clicks element IDs and reads state needs the page's JS to run, a real DOM, and
   *layout* (geometry: `getBoundingClientRect`, hit-testing, the a11y tree is built
   in a post-layout render phase). **Raster/paint is the one genuinely optional
   stage.** This is exactly Lightpanda's thesis, and it reshapes the target: we are
   not trying to rebuild Chromium-in-wasm; we are trying to get *real framework JS*
   to run against a *real layout-bearing DOM*.

3. **The real wall is not engine speed — it's Web-API surface breadth.** Every data
   point converges here: Servo carries ~539 WebIDL interfaces; jsdom/happy-dom/
   linkedom differ by *coverage*, not engine; Lightpanda's failures are missing APIs
   (`indexedDB`, `Element.scrollTo`), not slow V8. Our Boa problem is *also* mostly
   this: "hundreds of missing browser APIs." Engine speed is a real but *secondary*
   wall.

4. **The most promising non-Chromium, non-Playwright path that exists *today* is a
   brokered host-side headless engine — Lightpanda (Zig + V8 + native DOM, no
   paint, CDP).** It is the only near-ready engine that is neither a Chromium fork
   nor Playwright. It is beta and breaks on some SPAs, but it is the least-bad
   real option and fits our Dock-broker model. It is **not** wasm-able (embeds V8,
   a JIT) — it is a *host service behind the membrane*, which our architecture
   already supports (the same tier as kernel.sh in MEMORY).

5. **The most promising greenfield *in-wasm* bet is: StarlingMonkey (real
   SpiderMonkey-in-wasm) running a JS-implemented DOM (happy-dom) as guest JS,
   pointed at our Blitz renderer for layout/paint, with host-brokered fetch.** This
   sidesteps the IDL-binding problem (the DOM is *JS*, not 539 hand-bound Rust
   interfaces) and replaces Boa with an engine that can actually execute React's
   JavaScript. **No shipped prior art exists for this exact shape** — it is genuine
   greenfield, high-effort, high-risk on the layout-delegation bridge, but it is the
   only in-wasm path with a credible route to heavy SPAs.

---

## 1. The wasm browser-engine landscape — what actually runs in wasm

**Nothing renders HTML/CSS + runs JS fully in wasm.** Confirmed across Servo,
Ladybird, Flow, Kosmonaut, Blitz. The two things constantly conflated must be kept
apart:

- **A wasm app *renting the host browser's* DOM** (Dioxus-web, Yew, Leptos, egui):
  mature, production — but the *host* engine does layout/paint; the wasm module just
  calls JS glue via `wasm-bindgen`/`web-sys`. **Not an engine in wasm.** Irrelevant
  to us (we have no host browser engine; that's the point).
- **A rendering engine *compiled to* wasm that paints to canvas without the host
  DOM** (Blitz): rare, experimental, **JS-less**. This is us.

| Engine | In wasm? | JS / interactivity | Maturity |
|---|---|---|---|
| **Servo (full)** | **No** — native SpiderMonkey + GL + heavy threads | Real SpiderMonkey | Pre-1.0 engine; production *components* |
| Servo `html5ever` (parser) | **Yes, in-browser** (~454 KB) | n/a | Production parser |
| Servo Stylo → wasm | Compiles with a small patch, **untested at runtime** | n/a | Unproven |
| **Ladybird** | **No** — multi-process native is its security model | Own LibJS (~97.8% test262) | Pre-alpha (alpha target 2026) |
| Ekioh **Flow** | **No** — multithreaded-native is the whole value prop | SpiderMonkey | Production (embedded), beta |
| Kosmonaut | No | No | Abandoned (~2021) |
| **Blitz → wasm** | **Yes** (Vello-hybrid over WebGL) | **No JS** (Rust/Dioxus events) | Pre-alpha |
| Vello + wgpu (paint only) | Yes (WebGPU; WebGL / CPU-SIMD fallback) | n/a | Shipping / maturing |

**Servo** is the reference for *why* a full engine resists wasm: it embeds native
SpiderMonkey (mozjs), needs OpenGL/WebGL, native networking, and heavy
multithreading — all hostile to `wasm32`'s single-linear-memory, no-JIT,
single-thread-by-default model. Servo is alive and well-funded (Linux Foundation
Europe, Igalia, NLnet, Sovereign Tech Fund; CSS Grid, flexbox, inline SVG, variable
fonts all landed 2024–2025) but **as a browser it is pre-1.0**, and the Vello/wgpu
migration (issue #37149) is a *Todo*, not shipped. The Tauri-Verso backend is
explicitly experimental ("not as feature rich as current backends").

**Blitz** is the one real win and it is *our* stack: Stylo + Taffy + Parley + Vello,
genuinely building on `wasm32` (`HOWTO_WASM.md`), drawing to canvas via
`anyrender_vello_hybrid` + WebGL, bypassing the host DOM. But by deliberate design it
ships **no JS engine** — interactivity is meant to come from *Rust* (Dioxus event
handlers). The README defers "JavaScript execution, browser-grade network caching and
security, and process-isolation" and is pre-alpha ("would not yet recommend building
apps with it"). So Blitz gives us the renderer; the JS+DOM-interactivity half is on us.

**Ladybird** is interesting as an *independent, from-scratch* engine with a
surprisingly conformant own JS engine (LibJS, ~97.8% test262, reportedly 2nd after
Firefox), but it is **structurally anti-wasm**: its security model *is* OS processes +
sandboxing, it needs raw sockets / native GPU / IPC / threads, and there is no goal to
ship it in wasm. (Note: "WebAssembly in Ladybird" = LibWasm, the VM that *runs* a
page's wasm — the opposite direction.) Pre-alpha; stopped taking public PRs June 2026.

**Verdict for §1.** The in-wasm rendering substrate is *solved enough* (Blitz/Vello),
and that is the part we already have. The unsolved part — interactivity — is not an
engine-port problem; it is a JS-engine + DOM-binding problem (§2, §3).

*Sources:* https://servo.org/blog/2025/01/31/servo-in-2024/ ·
https://github.com/servo/servo/issues/37149 ·
https://github.com/servo/servo/discussions/28070 ·
https://github.com/DioxusLabs/blitz/blob/main/README.md ·
https://github.com/DioxusLabs/blitz/blob/main/HOWTO_WASM.md ·
https://ladybird.org/newsletter/2026-04-30/ ·
https://dzfrias.dev/blog/ladybird-wasm-0/ · https://www.ekioh.com/flow-browser/ ·
https://github.com/twilco/kosmonaut · https://github.com/linebender/vello

---

## 2. JS engines that could run REAL framework bundles in/near wasm

We are past Boa: it's a pure-Rust interpreter, no JIT, no DOM, and exactly the class
that overflows on heavy bundles. The realistic ladder, ranked by "can it run React's
JS at all" × maturity:

1. **StarlingMonkey (Bytecode Alliance) — the one to take seriously.** Full
   SpiderMonkey compiled to wasm, targeting WASI 0.2 / the Component Model. It is a
   *real, full* engine with the complete ES standard library and parser, so **it can
   execute React's JavaScript** (React-the-library is plain ES; SSR/`renderToString`
   works). It ships standards-compliant `fetch`, WHATWG Streams, TextEncoder/Decoder,
   and a Component-Model event loop, and is **in production at Fastly (JS Compute) and
   Fermyon (Spin JS SDK).** *Crucially it provides NO DOM, no `window`/`document`, no
   layout* — it adds *edge/server* web APIs, not the rendering DOM. That gap is the
   project (see §3). JIT caveat below.

2. **QuickJS / quickjs-ng + Javy — production-real but small.** Javy (Bytecode
   Alliance, ex-Shopify) embeds QuickJS in wasm; in production for Shopify Functions.
   It can run React's JS and do `renderToString`-style SSR (Fermyon demoed a moderate
   React page → ~30 kB HTML in wasmtime). But QuickJS is a *compact bytecode
   interpreter, no JIT* — deliberately tiny and slow, great for short-lived sandboxed
   functions, **not** a perf story for a heavy interactive bundle. Same ceiling as
   Boa, just more battle-tested. ~869 KB static.

3. **Boa / Kiesel / Nova — interpreters, no JIT, can't carry React.** Boa is the most
   conformant pure-Rust engine (~94% test262) but it is exactly what we already have.
   Kiesel (Zig, ~25% test262) and Nova (Rust, data-oriented heap — architecturally
   interesting, ~75–85% test262 target) are promising *research*, not production, and
   none can run React as a real app today.

4. **Porffor (CanadaHonk) — the AOT angle; right idea, not ready.** An AOT
   JS/TS → Wasm/C compiler — the north star of "ship no interpreter, compile the
   page's JS straight to wasm." Its own README: *"Research project... Expect nothing
   to work! Only very limited JS is currently supported."* Hard blockers for our use:
   **no `eval`/`Function`** (it's AOT — and bundlers/frameworks use dynamic code),
   no cross-scope variables beyond args/globals, limited buggy async, no WASI. **It
   cannot compile a React bundle and won't for years.** Watch, don't bet.

### The JIT-in-wasm wall (and the only real mitigation)

JS is dynamically typed; native engines win by JIT-ing type-specialized machine code
at runtime. **wasm forbids adding code at runtime** (by design — security/determinism),
so the entire JIT strategy is unavailable in-sandbox. This is *the* hard ceiling.

The serious research answer is **partial evaluation — `weval`**: ahead-of-time,
partially-evaluate the SpiderMonkey interpreter against a specific JS program,
pre-compiling its inline-cache fragments into something compiler-like. Measured:
**Octane ~2.77× geomean (max ~4.4×)**, approaching SpiderMonkey's *native baseline*
compiler — *not* the full optimizing JIT. `weval` is **merged into StarlingMonkey but
experimental and flag-gated** (`--enable-experimental-aot`). PLDI 2025 paper.

**Honest ceiling: the best in-wasm JS speedup is ~2–5× over a plain wasm interpreter,
not the 10–100× a native JIT gives.** If we genuinely need browser-grade perf on
arbitrary heavy interactive bundles, the consistent industry answer is a real engine
out-of-process (which is Tier-2/Lightpanda, §4, not in-wasm).

**WasmGC does *not* rescue this.** WasmGC lets a *new* guest language reuse the host
VM's GC; mature JS engines (SpiderMonkey, QuickJS) ship their own GC in linear memory
and don't restructure onto WasmGC. It helps Kotlin/Dart/Java→wasm, not a ported JS
engine's heap.

*Sources:* https://github.com/bytecodealliance/StarlingMonkey ·
https://github.com/bytecodealliance/ComponentizeJS ·
https://thenewstack.io/spin-starlingmonkey-equals-javascript-for-webassembly/ ·
https://github.com/bytecodealliance/javy ·
https://developer.fermyon.com/wasm-languages/javascript ·
https://github.com/boa-dev/boa · https://github.com/trynova/nova ·
https://github.com/CanadaHonk/porffor/blob/main/README.md ·
https://cfallin.org/blog/2024/08/27/aot-js/ ·
https://cfallin.org/blog/2024/08/28/weval/ ·
https://cfallin.org/pubs/pldi2025_weval.pdf ·
https://developer.chrome.com/blog/wasmgc

---

## 3. DOM ↔ JS binding at scale — the actual large body of work

**The bottleneck is Web-API/DOM breadth, not engine speed.** Every line of evidence
points one way:

- Servo binds its Rust DOM to SpiderMonkey via **WebIDL codegen** — one `.webidl` per
  interface, ~**539** of them, build-time-generated reflector glue. Servo's own
  modernization narrative is about taming this *surface area*, never "SpiderMonkey is
  slow."
- JS-implemented DOMs differ by **coverage**, on the *same* engine:
  - **jsdom** — most complete, but **layout/navigation explicitly out of scope**
    (computed styles empty, `getBoundingClientRect` ≈ zeros). The Jest standard.
  - **happy-dom** — tuned subset, **~7.5× faster than jsdom** (Vitest: 4.2s vs 31.5s),
    and critically supports **Custom Elements, Declarative Shadow DOM, MutationObserver,
    TreeWalker, Fetch** — the surface interactive frameworks actually need.
  - **linkedom** — minimal, SSR/serialization-focused, very fast — but **no event
    propagation, no faithful MutationObserver** → a serializer, not an interaction
    substrate. "linkedom runs React" is true only for `renderToString`, *not* a
    hydrated app.

**React SSR vs hydration is the dividing line.** `renderToString` needs *no* DOM
(linkedom path, production-real). `hydrateRoot` (client render + interactivity) needs a
live, event-dispatching, layout-bearing DOM — **jsdom/happy-dom can drive it; linkedom
cannot.** Heavy interactive SPAs = the hydration case.

### The greenfield idea: a JS-DOM *inside* the in-wasm JS engine, layout delegated to Blitz

Run **happy-dom (or jsdom) as guest JavaScript inside StarlingMonkey**, and point its
layout/geometry queries at **our Blitz renderer** (Stylo + Taffy) via host calls.

- **Why it's attractive:** it *sidesteps the 539-interface IDL-binding problem
  entirely* — the DOM is *JS code*, not hand-bound Rust. StarlingMonkey runs ordinary
  JS modules; happy-dom is pure JS with no native deps. You get a manipulable,
  event-dispatching DOM that real framework JS can hydrate against, without writing
  hundreds of Rust↔JS bindings. This is the single biggest leverage point in the whole
  problem.
- **The unsolved half — layout delegation has *no shipped prior art*.** happy-dom/jsdom
  deliberately compute *no* layout; that's the whole reason they're fast. A hydrating
  React app calls `getBoundingClientRect`, `offsetWidth`, `scrollTo`, `Intersection
  Observer`, `ResizeObserver`, `getComputedStyle` — all of which need *real geometry*.
  The bridge would have to: extract the guest-JS DOM tree + styles, hand them to Blitz
  (Stylo style + Taffy layout) in Rust, and project computed boxes/geometry *back* into
  the guest DOM's layout-query methods. **No system does this.** Real systems do the
  opposite (Lightpanda: native DOM + V8, no renderer; Servo: all-native; Blitz: native
  renderer, no JS-DOM bridge). This is the core greenfield engineering + the core risk.
- **Inherited gaps:** happy-dom still lacks ResizeObserver, CSS media queries, complex
  navigation; jsdom lacks layout. So even the "easy" JS-DOM half is partial and we'd be
  backfilling APIs — i.e. we re-enter the breadth problem, just in JS instead of Rust
  (cheaper to write, but still the long tail).

**deno_dom / deno_core** confirm the pattern: Deno ships *no* built-in DOM; deno_dom is
SSR-focused, perennially alpha, on `html5ever`. Parsing is the shared, solved part
(everyone — Servo, Lightpanda, deno_dom, Blitz — sits on `html5ever`); the live,
scriptable, layout-bearing DOM is the expensive, unshared part.

*Sources:* https://book.servo.org/architecture/script.html ·
https://github.com/servo/servo/tree/master/components/script/dom/webidls ·
https://github.com/jsdom/jsdom · https://github.com/capricorn86/happy-dom ·
https://webreflection.medium.com/linkedom-a-jsdom-alternative-53dd8f699311 ·
https://react.dev/reference/react-dom/client/hydrateRoot ·
https://github.com/bytecodealliance/StarlingMonkey · https://deno.land/x/deno_dom

---

## 4. Lightpanda — the near-ready Tier-2 that is neither Chromium nor Playwright

**Architecture.** From-scratch headless browser in **Zig** (not a Blink/WebKit fork),
built explicitly for AI agents / automation / scraping. Stack: **V8** (JS, via Zig→C
bindings) + **html5ever** (parse, via FFI) + **zigdom** (native Zig DOM — migrated off
Netsurf libdom, merged late-2025) + **libcurl** (HTTP). **Does no rendering/painting by
design** — drops CSS layout-to-pixels, image decode, GPU compositor, font raster, a11y
tree; keeps DOM + JS + network. Builds on Zig 0.15.2.

**Why it fits us.** It speaks **CDP** (Chrome DevTools Protocol) over WebSockets, so
**Puppeteer/Playwright/chromedp connect by pointing the WS endpoint at it** — "zero
code changes" (bounded by which CDP methods + Web APIs exist). It is a single native
binary/library (Go wrapper published) — embeds far cheaper than Chromium, fits a
**brokered host service behind the Dock membrane** (the same tier our MEMORY already
designates for kernel.sh / host-side heavy automation). It is the *only* genuinely
non-Chromium, non-Playwright engine that is near-ready.

**Verified performance.** The ~9–11× faster / ~16× less RAM claims trace to a
*reproducible public benchmark* (`lightpanda-io/demo`, BENCHMARKS.md): 100 pages →
123 MB vs Chrome 2 GB (~16×); 5 s vs 46 s (~9×) on AWS m5.large over a 933-URL crawl.
Better than typical vendor marketing — **but the corpus is lightweight JS pages, not
heavy React SPAs**, exactly where the advantage shrinks. Treat as directionally true
for high-concurrency lightweight automation, not universal.

**Honest limits (the hype to flag).** **Beta**, maintainers' own disclaimer ("you may
encounter errors or crashes"). Partial Web-API surface: a documented Stripe-docs SPA
returned 200 + title but **empty body** — hydration failed on `indexedDB is not
defined` + `Element.scrollTo is not a function`. No WebGL/WebRTC/media, no screenshots.
Complex React/Vue/Angular SPAs "may have issues." **AGPL-3.0** (network-use copyleft —
matters if we embed/expose it). **Not wasm-able** (embeds V8, a JIT) → it is a *host
service*, not an in-wasm artifact. Pre-seed funded (ISAI + AI angels incl. Mistral/HF/
Dust founders), June 2025; pre-commercial.

**Where it fits.** Lightpanda is the **least-bad non-Chromium Tier-2 you can adopt
this quarter**: a brokered headless engine for agent navigation that runs real V8 (so
real framework JS), exposes CDP (so our existing CDP/agent tooling drives it), and
never bundles Chromium. The cost: it's beta, AGPL, and breaks on the SPA long tail. It
honors our "no native browser in the wasm security model" line by living *behind the
membrane as a brokered service*, exactly like kernel.sh.

*Sources:* https://github.com/lightpanda-io/browser ·
https://lightpanda.io/blog/posts/migrating-our-dom-to-zig ·
https://lightpanda.io/blog/posts/cdp-under-the-hood ·
https://github.com/lightpanda-io/demo/blob/main/BENCHMARKS.md ·
https://lightpanda.io/blog/posts/lightpanda-raises-preseed ·
https://www.scrapingbee.com/blog/lightpanda-headless-browser/

---

## 5. The sandbox/runtime frontier — does the wasm platform unblock a fuller engine?

The wasm stack matured a lot (Wasm 3.0 finalized Sept 2025; WASI 0.2 = production floor;
WASI 0.3 async ratified Feb 2026) — **but every hard browser-engine piece is still
flag-gated/experimental in standalone runtimes, or the realistic design pushes the hard
part back onto the host.**

**Networking / self-fetching subresources.** `wasi-sockets` shipped in WASI 0.2.0
(raw TCP/UDP, in wasmtime `p2`) — so outbound connect works. **But TLS is an explicit
*non-goal* of the sockets spec** (plaintext only); HTTPS needs host-side `wasi-tls`
(Rustls; p3 binding "experimental, unstable, incomplete"). DNS is name→IP only.
**`wasi-http`'s outgoing handler is the clean supported HTTPS path — host does the
TLS.** So "the engine fetches its own subresources" realistically means **host-brokered
wasi-http with host-terminated TLS** — which is *exactly our current model*. Raw-socket
+ in-guest-TLS to mimic a real browser network stack is **not** the mature path. Our
host-brokered fetch is correct, not a limitation to remove.

**Per-proposal wasmtime status (the engine-relevant ones):**

| Proposal | Why a browser/JS engine wants it | wasmtime status |
|---|---|---|
| **Threads** (shared mem + atomics) | parallel layout / JS workers | Stable since 15.0 |
| **shared-everything-threads** | the *clean* multithread model | Experimental, unusable |
| **Wasm GC** | managed JS heap | Complete since 27.0, flag-gated — **but JS engines keep own GC in linear mem; doesn't help** |
| **Exception handling (exnref)** | JS try/catch, C++ setjmp | Landed late 2025, ~production-ready — cleanest win |
| **Stack switching / typed continuations** | **JS async / event-loop backbone** | Experimental, x64-only, no Windows, no GC integration — **biggest gap** (no JSPI analog in wasmtime) |
| **memory64** | >4 GB heaps | Shipped, off by default |

**Read:** "Wasm 3.0 is done, so a JS engine just runs in wasm" is **overstated**. The
two structurally important gaps for a real interactive engine are (a) the **event-loop
story (stack switching)** is immature, and (b) a **real JS heap on WasmGC** isn't done.
Exceptions are the one clean recent win.

**WASIX (Wasmer)** adds real pthreads + full BSD sockets + fork/exec/signals — lets
unmodified POSIX (CPython, PostgreSQL, tokio/hyper) run — and is the *best* case for a
multithreaded engine. But it is **Wasmer-only, non-standard, preview**, and adopting it
**breaks our wasmtime-only commitment** (MEMORY: runtime is wasmtime-only; Wasmer/WASIX
deliberately not adopted). Don't re-litigate.

**Browser/agent runtimes as wasm components.** No full browser engine compiled to wasm
exists (Chromium/WebKit/Gecko/Servo/Ladybird all absent). The only "browser in wasm"
that works is **x86 emulation** (v86 / WebVM / CheerpX) — virtualization, not an engine
port — irrelevant to us. Blitz is the closest *engine* and runs *no JS*. The legitimate,
growing category is **agent/tool runtimes as wasm** (Extism + mcp.run; Fermyon Spin —
Akamai-acquired Dec 2025; Microsoft Wassette "not production ready") — none of which is
a headless browser. Notably, heavy code/agent-sandbox providers (Cloudflare = V8
isolates; E2B/Modal/Browserbase = microVMs/gVisor) chose **non-wasm** isolation for
exactly the workloads we're discussing.

*Sources:* https://webassembly.org/news/2025-09-17-wasm-3.0/ ·
https://github.com/WebAssembly/wasi-sockets ·
https://docs.wasmtime.dev/api/wasmtime_wasi_tls/index.html ·
https://docs.wasmtime.dev/stability-wasm-proposals.html ·
https://github.com/WebAssembly/shared-everything-threads/blob/main/proposals/shared-everything-threads/Overview.md ·
https://cfallin.org/blog/2025/11/06/exceptions/ ·
https://bytecodealliance.org/articles/wasmtime-27.0 · https://wasix.org/docs/explanation/features ·
https://github.com/extism/extism · https://www.fermyon.com/blog/fermyon-joins-akamai ·
https://github.com/microsoft/wassette · https://labs.leaningtech.com/blog/webvm-server-less-x86-virtual-machines-in-the-browser

---

## 6. How computer-use agents actually drive the web (and the minimum engine)

The dominant pattern is uniform: **a real browser engine, almost always Chromium,
driven over CDP** (directly or via Playwright/Puppeteer). The *differences are in the
perception layer, not the engine*:

- **browser-use** (most-used OSS): real Chromium; **dropped Playwright in 2025 for raw
  CDP** (latency). Treats real rendering as essential.
- **Claude computer-use**: drives a whole desktop via **screenshots + synthetic OS
  input** — the most rendering-dependent extreme (needs a real pixel surface).
- **Skyvern** (production RPA): Playwright + vision models.
- **WebVoyager** (arXiv 2401.13919): real browser via Selenium; GPT-4V + **Set-of-Marks
  on screenshots**; 59% on a curated 15-site set.
- **WebArena / VisualWebArena**: benchmarks; observation configurable as DOM /
  screenshot / **a11y tree** (WebArena baseline = a11y tree + element IDs, text-only).

**Do any avoid a real browser? Essentially none** — all need something that runs the
page's JS and builds a DOM. The only genuine non-Chromium engine in use is Lightpanda.

**Representation debate (no universal winner).** **Set-of-Marks** (numbered overlays so
the VLM references IDs not coordinates) is strongest for capable VLMs (VWA headline;
WebVoyager adopts it) — *but SeeAct found SoM "not effective,"* preferring fused
HTML-structure + visuals. The **a11y tree** is compact and structure-preserving
(WebArena baseline) but degrades on image-dense pages and can't read pixel-encoded
content. Raw DOM is most complete but explodes (YouTube ≈ 800k tokens → everyone
denoises). Pure pixels are most general but hardest to ground.

### The key result: minimum engine = JS + DOM + **layout geometry**, paint optional

Pipeline: parse → DOM → run JS → style → **LAYOUT** → PAINT → composite.

- **DOM + JS are mandatory** — modern apps build the UI in JS; without it there are no
  elements to click.
- **Layout (geometry) is required even for DOM-only / a11y-tree agents** — two facts:
  the **a11y tree is constructed in a render phase *just after layout*** (it depends on
  layout), and clicking needs element geometry (`getBoundingClientRect` forces
  synchronous layout; CDP clicks hit-test against the layout tree). So coordinate
  agents *and* a11y-tree agents both need layout.
- **PAINT/raster is the genuinely optional stage** — nothing about "click element #14,
  read its text" requires rasterized pixels. This is Lightpanda's thesis.

**What breaks without real paint:** canvas/WebGL/video (content lives in a pixel buffer,
no DOM nodes), OCR / image-meaning tasks (VWA's OCR tasks score lowest), CSS-only visual
state (color/position conveying meaning with no ARIA/DOM hook), and heavy canvas apps
(Figma/Docs). That's the *visual tail* (~10%); the structured/form/navigation majority
(~90%) needs no paint.

**Tension to flag:** "agents never look at pixels, so don't paint" is true **only for
DOM/a11y-tree agents**. It's false for the vision/SoM/coordinate agents (WebVoyager,
Skyvern, Claude) that currently *perform best*. A no-paint engine and a top-of-leaderboard
vision agent are somewhat mutually exclusive — marketing glosses this. Also sobering:
open-web agent benchmarks are still *weak* (VWA best ≈16% vs 88.7% human; WebArena GPT-4
≈14%) — heavy-SPA autonomy is unsolved regardless of engine.

**Implication for us:** because we *do* have Blitz (Stylo style + Taffy layout +
Vello paint), we are uniquely positioned for the **DOM + a11y-tree + layout-geometry
agent** — the cheapest viable representation — *and* we can paint when the visual tail
demands it. The missing piece is not perception or paint; it is **running the page's
real framework JS against a layout-bearing DOM** (§2 + §3).

*Sources:* https://browser-use.com/posts/playwright-to-cdp ·
https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool ·
https://github.com/Skyvern-AI/skyvern · https://arxiv.org/abs/2401.13919 ·
https://arxiv.org/html/2307.13854v4 · https://arxiv.org/html/2401.13649v2 ·
https://osu-nlp-group.github.io/SeeAct/ · https://browser.engineering/accessibility.html ·
https://www.debugbear.com/blog/forced-reflows · https://github.com/lightpanda-io/browser

---

## 7. Ranked paths to heavy-SPA + computer-use without Chromium/Playwright

Each path: **what it is · feasibility · effort · key risk.**

### Path A — Brokered Lightpanda as Tier-2 (host service, CDP) — *adopt now*
- **What:** run Lightpanda (Zig + V8 + native DOM, no paint) as a brokered host
  service behind the Dock; drive it over CDP from our existing agent tooling. Real V8
  = real framework JS; never bundles Chromium; not Playwright.
- **Feasibility:** **High — the only near-ready non-Chromium engine.** It exists, runs
  V8, speaks CDP, has a Go wrapper.
- **Effort:** **Low–medium** — wire it as a broker target + CDP client; honor the
  membrane boundary (same tier as kernel.sh).
- **Key risk:** beta + partial Web-API surface (SPA hydration failures on missing APIs:
  `indexedDB`, `scrollTo`); **AGPL-3.0** network-copyleft; not wasm (host-side only, so
  it sits *outside* the all-in-wasm guarantee — acceptable as a brokered Tier-2, not as
  the in-wasm renderer). No paint → pair with our Blitz for the visual tail if needed.

### Path B — StarlingMonkey + JS-DOM (happy-dom) → Blitz layout — *the greenfield bet*
- **What:** replace Boa with **StarlingMonkey** (real SpiderMonkey-in-wasm, runs
  React's JS); run **happy-dom as guest JS** to get an event-dispatching DOM without
  hand-binding 539 IDL interfaces; build a bridge that delegates layout/geometry
  queries (`getBoundingClientRect`, `getComputedStyle`, observers) to **Blitz** (Stylo
  + Taffy) in Rust, projecting computed boxes back into the guest DOM; keep
  host-brokered fetch.
- **Feasibility:** **Medium** — every component is real and in-wasm-proven
  *individually* (StarlingMonkey production; happy-dom pure JS; Blitz renders in wasm);
  **the integration has no prior art.**
- **Effort:** **High** — the layout-delegation bridge is novel; plus backfilling the
  happy-dom API long tail (ResizeObserver, media queries) and wiring the guest-JS↔Rust
  marshalling.
- **Key risk:** (1) **layout-delegation bridge is unproven** — nobody has shipped
  "in-wasm JS-DOM → external native layout"; (2) **no JIT** → even StarlingMonkey is
  interpreter-speed (weval AOT is flag-gated, ~2–5×), so heavy bundles run but *slowly*;
  (3) the API long tail re-emerges in JS. **This is the highest-upside in-wasm path and
  the one with the most genuinely new engineering.**

### Path C — StarlingMonkey + hand-bound Rust DOM (Servo-style) on Blitz
- **What:** same engine swap, but bind Blitz's *Rust* DOM to StarlingMonkey via WebIDL
  codegen (the Servo pattern) instead of running a JS-DOM.
- **Feasibility:** **Medium-low.**
- **Effort:** **Very high** — this is the ~539-interface surface Servo spent years on;
  it is the exact breadth problem we want to *avoid*. DRY/least-code rules argue against
  it.
- **Key risk:** you sign up to re-implement and maintain hundreds of Web-platform
  interfaces in Rust — the single largest, least-leveraged body of work in the space.
  Only choose this if guest-JS-DOM (Path B) proves unworkable for marshalling/perf.

### Path D — DOM-only agent on our Blitz, no heavy-JS rendering — *pragmatic floor*
- **What:** lean into what we have: Blitz renders fetched pages (incl. server-rendered
  HTML + the JS Boa *can* run), expose the DOM + a11y tree + layout geometry to the
  agent, let it click/read/type via synthetic events. Accept that *client-rendered* SPAs
  that need heavy framework JS are out of scope here.
- **Feasibility:** **High** — closest to shipped; we already render to text+PNG and run
  imperative JS.
- **Effort:** **Low.**
- **Key risk:** **does not solve heavy SPAs** — the whole premise of the question. It
  covers SSR'd content, static, and lightly-scripted pages. Good as the always-available
  in-wasm floor *under* Path A/B, not a substitute for them.

### Path E — Porffor-style AOT-compile the page's JS to wasm — *research only*
- **What:** AOT-compile a page's JS straight to wasm (no interpreter shipped).
- **Feasibility:** **Very low today.** Porffor can't compile React (no `eval`/`Function`,
  partial language); building this ourselves = reimplementing JS + stdlib.
- **Effort:** **Extreme** (multi-year).
- **Key risk:** dynamic `eval`/`Function` and full ES semantics are fundamentally hostile
  to whole-program AOT; bundlers/frameworks rely on them. Track Porffor; do not build.

---

## 8. The single most promising greenfield bet

**Path B: StarlingMonkey (real SpiderMonkey-in-wasm) + happy-dom as a guest-JS DOM,
with layout/geometry delegated to our Blitz renderer and fetch host-brokered.**

Why this one:
- It **directly removes our actual wall** — Boa can't run heavy bundles; StarlingMonkey
  is a *full, production* JS engine that runs React's JavaScript, in wasm, today.
- It **dodges the single biggest cost in the field** — the ~539-interface IDL-binding
  problem — by letting the DOM be *JavaScript* (happy-dom) rather than hand-bound Rust.
  This is the highest-leverage architectural insight in the whole landscape.
- It **reuses everything we already built** — Blitz (Stylo + Taffy + Vello) becomes the
  layout/paint backend the JS-DOM delegates to; host-brokered fetch stays (and §5 says
  that's *correct*, not a limitation). It stays **all-in-wasm** (honoring the security
  model) where Lightpanda cannot.
- It is **genuinely greenfield** — the layout-delegation bridge has no prior art — which
  is the risk *and* the moat. If we build "in-wasm JS-DOM → native Rust layout," we own a
  capability nobody else has.

The honest counterweight: **no JIT means it will be slow on the heaviest bundles** (weval
AOT is flag-gated, ~2–5×), and the layout bridge is hard. So pair it with **Path A
(Lightpanda Tier-2)** as the pragmatic escape hatch for the pages where in-wasm perf or
the SPA long tail loses — Lightpanda behind the membrane is the least-bad real engine for
"this page needs more than we can do in wasm," and it's still not Chromium and not
Playwright.

**Recommended posture:** Path D now (floor, ~free), Path A this quarter (brokered Tier-2,
real engine, low effort), Path B as the strategic in-wasm R&D bet (replace Boa →
StarlingMonkey first; then prototype the happy-dom-on-Blitz bridge). Avoid Path C unless
B's marshalling fails; ignore Path E except as a watch-item.

---

## 9. Impossible-today vs hard-but-emerging

**Genuinely impossible today (don't plan around it):**
- A full browser engine — HTML/CSS layout + JS interactivity + own subresource fetching
  — running **inside** a wasm sandbox. No production or proven prototype anywhere.
- **Native-JIT JS performance in wasm.** wasm forbids runtime codegen by design; the
  ceiling is partial-eval AOT (~2–5×), not the 10–100× a real JIT gives. Not coming.
- **Raw-socket + in-guest-TLS** browser-style networking in wasmtime. TLS is a sockets-
  spec non-goal; host-terminated TLS (wasi-http) is the only mature path. (For us this
  is fine — it *is* our model.)
- AOT-compiling an arbitrary React bundle to wasm (Path E) — blocked by `eval`/`Function`
  + full ES semantics.

**Hard but emerging (credible 1–3 yr bets):**
- **StarlingMonkey replacing Boa** — production engine, real React JS in wasm — *available
  now*, "hard" only in integration.
- **weval AOT** for in-wasm JS speed — merged, flag-gated, ~2–5×; will mature.
- **In-wasm JS-DOM → native-renderer layout delegation** (the Path B bridge) — no prior
  art, but every piece exists; this is the buildable frontier.
- **wasm event-loop / async via stack switching** — experimental (x64-only, no Windows);
  improving; matters for a faithful JS event loop in-sandbox.
- **Lightpanda maturing past beta** — partial Web-API coverage is closing; the
  no-paint-headless-for-agents thesis is sound.

**Solidly real today (use these):**
- Blitz/Vello in wasm (layout + paint) — *we have it.*
- StarlingMonkey / QuickJS-Javy as DOM-less JS engines in wasm (production).
- happy-dom / jsdom / linkedom as JS DOMs (pure JS, runnable in a wasm JS engine).
- Lightpanda as a brokered host CDP engine (beta but usable).
- Host-brokered fetch via wasi-http with host TLS (the correct, mature model).

---

## 10. Concrete next-eval list (projects / papers / crates with links)

**Engines / runtimes**
- StarlingMonkey — https://github.com/bytecodealliance/StarlingMonkey · ComponentizeJS —
  https://github.com/bytecodealliance/ComponentizeJS
- weval (partial-eval AOT) — https://github.com/bytecodealliance/weval · PLDI 2025 —
  https://cfallin.org/pubs/pldi2025_weval.pdf · context —
  https://cfallin.org/blog/2024/08/27/aot-js/
- Javy / QuickJS-in-wasm — https://github.com/bytecodealliance/javy
- Lightpanda — https://github.com/lightpanda-io/browser · benchmarks —
  https://github.com/lightpanda-io/demo/blob/main/BENCHMARKS.md · DOM-to-Zig —
  https://lightpanda.io/blog/posts/migrating-our-dom-to-zig
- Porffor (watch-only) — https://github.com/CanadaHonk/porffor
- Blitz (ours) — https://github.com/DioxusLabs/blitz · wasm —
  https://github.com/DioxusLabs/blitz/blob/main/HOWTO_WASM.md

**DOM libraries (candidate guest-JS DOM)**
- happy-dom — https://github.com/capricorn86/happy-dom · jsdom —
  https://github.com/jsdom/jsdom · linkedom —
  https://webreflection.medium.com/linkedom-a-jsdom-alternative-53dd8f699311

**Binding reference**
- Servo `script` crate / WebIDL — https://book.servo.org/architecture/script.html ·
  IDL surface — https://github.com/servo/servo/tree/master/components/script/dom/webidls

**Sandbox frontier**
- Wasm 3.0 — https://webassembly.org/news/2025-09-17-wasm-3.0/ · wasmtime proposal
  status — https://docs.wasmtime.dev/stability-wasm-proposals.html · exceptions —
  https://cfallin.org/blog/2025/11/06/exceptions/ · wasi-tls —
  https://docs.wasmtime.dev/api/wasmtime_wasi_tls/index.html

**Agent / computer-use papers**
- WebVoyager — https://arxiv.org/abs/2401.13919 · WebArena —
  https://arxiv.org/html/2307.13854v4 · VisualWebArena —
  https://arxiv.org/html/2401.13649v2 · SeeAct — https://osu-nlp-group.github.io/SeeAct/ ·
  browser-use → CDP — https://browser-use.com/posts/playwright-to-cdp · a11y/layout dep —
  https://browser.engineering/accessibility.html

---

## Master source list

All URLs cited above are collected here for convenience.

Servo & engines: https://servo.org/blog/2025/01/31/servo-in-2024/ ·
https://github.com/servo/servo/issues/37149 ·
https://github.com/servo/servo/discussions/28070 ·
https://book.servo.org/architecture/script.html ·
https://github.com/servo/servo/tree/master/components/script/dom/webidls ·
https://ladybird.org/newsletter/2026-04-30/ · https://dzfrias.dev/blog/ladybird-wasm-0/ ·
https://www.ekioh.com/flow-browser/ · https://github.com/twilco/kosmonaut ·
https://github.com/DioxusLabs/blitz/blob/main/README.md ·
https://github.com/DioxusLabs/blitz/blob/main/HOWTO_WASM.md ·
https://github.com/linebender/vello

JS engines & AOT: https://github.com/bytecodealliance/StarlingMonkey ·
https://github.com/bytecodealliance/ComponentizeJS ·
https://thenewstack.io/spin-starlingmonkey-equals-javascript-for-webassembly/ ·
https://github.com/bytecodealliance/javy ·
https://developer.fermyon.com/wasm-languages/javascript · https://github.com/boa-dev/boa ·
https://github.com/trynova/nova · https://codeberg.org/kiesel-js/kiesel ·
https://github.com/CanadaHonk/porffor/blob/main/README.md ·
https://cfallin.org/blog/2024/08/27/aot-js/ · https://cfallin.org/blog/2024/08/28/weval/ ·
https://cfallin.org/pubs/pldi2025_weval.pdf · https://github.com/bytecodealliance/weval ·
https://developer.chrome.com/blog/wasmgc

DOM libs: https://github.com/jsdom/jsdom · https://github.com/capricorn86/happy-dom ·
https://webreflection.medium.com/linkedom-a-jsdom-alternative-53dd8f699311 ·
https://react.dev/reference/react-dom/client/hydrateRoot · https://deno.land/x/deno_dom

Lightpanda: https://github.com/lightpanda-io/browser ·
https://lightpanda.io/blog/posts/migrating-our-dom-to-zig ·
https://lightpanda.io/blog/posts/cdp-under-the-hood ·
https://github.com/lightpanda-io/demo/blob/main/BENCHMARKS.md ·
https://lightpanda.io/blog/posts/lightpanda-raises-preseed ·
https://www.scrapingbee.com/blog/lightpanda-headless-browser/

Sandbox frontier: https://webassembly.org/news/2025-09-17-wasm-3.0/ ·
https://github.com/WebAssembly/wasi-sockets ·
https://docs.wasmtime.dev/api/wasmtime_wasi_tls/index.html ·
https://docs.wasmtime.dev/stability-wasm-proposals.html ·
https://github.com/WebAssembly/shared-everything-threads/blob/main/proposals/shared-everything-threads/Overview.md ·
https://cfallin.org/blog/2025/11/06/exceptions/ ·
https://bytecodealliance.org/articles/wasmtime-27.0 ·
https://wasix.org/docs/explanation/features · https://github.com/extism/extism ·
https://www.fermyon.com/blog/fermyon-joins-akamai · https://github.com/microsoft/wassette ·
https://labs.leaningtech.com/blog/webvm-server-less-x86-virtual-machines-in-the-browser

Agents: https://browser-use.com/posts/playwright-to-cdp ·
https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool ·
https://github.com/Skyvern-AI/skyvern · https://arxiv.org/abs/2401.13919 ·
https://arxiv.org/html/2307.13854v4 · https://arxiv.org/html/2401.13649v2 ·
https://osu-nlp-group.github.io/SeeAct/ · https://browser.engineering/accessibility.html ·
https://www.debugbear.com/blog/forced-reflows
