# Lightpanda-without-V8 — Research

A headless browser for agent computer-use that is **not Chromium and not V8**.
Lightpanda (github.com/lightpanda-io/browser) is the reference architecture; we
want its shape without the V8 dependency, ideally with a JS engine that runs
in/near WebAssembly (StarlingMonkey) or pure Zig/Rust.

What we already have: (a) **Blitz in wasm** = HTML/CSS layout + paint, no JS;
(b) **StarlingMonkey** (SpiderMonkey→wasm) running as a full eval host in
wasmtime with a real event loop + fetch + WebCrypto (runs React's JS).

> Evidence-based. Demoed/aspirational is flagged. Licenses flagged
> (AGPL/MPL/GPL are the watch-items). All URLs are primary sources.

---

## (a) Lightpanda's architecture and what is swappable

| Layer | What Lightpanda uses | Swappable? |
|---|---|---|
| Language | Zig (0.15.x), + Rust (html5ever), clang/cmake/Go for tests | — |
| **JS engine** | **V8**, via their own `zig-v8-fork` (MIT) | The whole point — but no abstraction layer exists |
| JS↔DOM binding | `zig-js-runtime` — Zig **comptime reflection** generates JS-facing fns from native Zig types | **V8-specific** (written against the V8 embedding API) |
| HTML parse | **html5ever** (Servo, Rust) | Reusable |
| **DOM** | **`zigdom`** — their own native Zig DOM (migrated OFF Netsurf libdom, Nov 2025) | Reusable (now engine-decoupled at the data-structure level) |
| CSS / layout / paint | **None.** DOM-only, no rendering, no geometry | n/a |
| Automation surface | **partial CDP** server over WebSocket (Puppeteer/Playwright/chromedp connect) | Reusable concept |
| License | **AGPL-3.0 + CLA** (`zig-v8-fork` is MIT) | copyleft liability |

**Key facts (all confirmed against primary sources):**

- **It uses V8, deliberately.** *"We didn't want to take on the added complexity
  of developing a new JavaScript engine. Instead, we chose to integrate an
  existing one: V8."* The strongest single data point in this whole report: a
  from-scratch **Zig** browser team that wanted maximum control still could not
  avoid V8 for the JS engine — because no non-V8 engine clears the bar (see (b)).
- **It does NO rendering.** Their thesis: a browser (1) fetches, (2) renders
  visually, (3) executes code — *"the goal was to address the first and third
  functions while omitting graphical rendering."* DOM-only, dump to HTML/Markdown.
  So its 9–11× speed / 16× memory win vs headless Chrome (real benchmark: chromedp
  over ~933 live pages on EC2 m5.large — credible, but vendor-run) comes
  **substantially from skipping layout/paint**, not from engine superiority.
- **It abandoned a native-C DOM bound to V8.** Originally V8 → Zig → **Netsurf
  libdom** (C). Migrated to its own Zig DOM (`zigdom`) in Nov 2025 due to
  "ever-increasing friction between our three layers" (events, Custom Elements,
  Shadow DOM, libdom needing ~5 allocs per `<div>`). **Net perf win was only
  single-digit %** — the payoff was architectural cohesion, not speed. *This is
  the central warning for any "bind a JS engine to a native DOM across a hard
  boundary" plan.*
- **Engine swap is aspirational, not built.** Project statement: *"In the future
  we may explore lighter alternatives."* There is **no engine-abstraction layer**;
  `zig-js-runtime` targets V8 directly. Swapping to SpiderMonkey/StarlingMonkey =
  rewriting the comptime binding generator against a new engine's embedding API.
  The DOM (`zigdom`) survives a swap; the bridge does not.

**Net for us:** the reusable assets are the **CDP-server pattern** and the
**`zigdom` + comptime-binding pattern** — but the binding is V8-coupled and the
repo is AGPL-3.0+CLA, so embedding it carries copyleft obligations. It is **not**
an engine-abstracted DOM you can slot SpiderMonkey under today.

---

## (b) Non-V8 JS engines — can any drive a real DOM + run framework JS today?

| Engine | Lang | test262 | Embed | Wasm host | Ships a DOM | React today? | Status |
|---|---|---|---|---|---|---|---|
| **SpiderMonkey** | C++/Rust | ~full | heavy | **StarlingMonkey (prod)** | no (you supply) | **Yes (engine ready)** | Production |
| **JavaScriptCore** | C++ | ~full | awkward | JSC.js (demo only) | no standalone | **Yes (engine ready)** | Production (Bun) |
| Boa | Rust | >90% | **easy** | yes (playground) | no | No (slow, "experimental") | Experimental |
| Nova | Rust | ~80% | designed-for | partial | no | No | Experimental (~99% hoped end-2026) |
| **Kiesel** | **Zig** | ~59% | n/a | n/a | no | No | Hobby/early |
| QuickJS-ng | C | ~100% | **trivial** | yes | no | No (no JIT → slow) | Mature but slow |

**Findings:**

- **Only SpiderMonkey and JavaScriptCore can run React-class apps in production
  today** — both are full browser engines extracted from Firefox/WebKit.
  Everything else is years out (Kiesel, Nova), too slow (Boa, QuickJS), or both.
- **No non-V8 engine ships a DOM.** Even the production ones give you only the
  engine + (for StarlingMonkey) web-platform plumbing. The browser must always
  supply its own DOM. Engine choice is *only* about executing the JS.
- **StarlingMonkey** (Bytecode Alliance, Fastly) = SpiderMonkey-in-wasm as a
  WASI-0.2 / Component-Model eval host: event loop, **fetch**, WHATWG **Streams**,
  **WebCrypto**, text encoding, `setTimeout`. **Production** at Fastly JS Compute
  + Fermyon Spin; it's the engine under ComponentizeJS/`jco`. It is a
  **server/worker runtime, not a browser** — **no DOM**. Exactly our existing lane.
- **Kiesel** (Zig, by ex-LibJS Linus Groh) is the all-Zig dream — but ~59%
  test262, no DOM, no embedding API. **Not viable; years away.** Its immaturity is
  *why* Lightpanda (a Zig shop) chose V8.
- **Nova** (Rust, data-oriented, NLnet-funded) is the most interesting future
  embeddable engine (~80% test262, hoping ~99% by end of 2026) — **watch-list, not
  today.** **Boa** is the most *ergonomic* Rust embed (>90% test262) but slow and
  self-labelled experimental — fine for plugins/config, not framework-on-DOM.

---

## (c) Reusable DOM / layout components

**Parse + DOM + style (NO layout):**
- **lexbor** (C, **Apache-2.0**) — HTML5 parse + DOM + CSSOM + selectors + encoding,
  one zero-dep library, ~235 MB/s, **production** (PHP 8.4 core `Dom\HTMLDocument`,
  Selectolax, Nokolexbor). Strongest single permissive parse/DOM lib. No geometry.
- **Netsurf libhubbub/libdom/libcss** (C, **MIT**) — the stack Lightpanda *left*.
  Stable but low-velocity, "in development", no layout (Netsurf's layout is in the
  **GPL-2.0** app, not the MIT libs).

**Full layout/paint engines:**
- **Blitz** (`blitz-dom`, Rust) — Stylo + Taffy + Parley + Vello. **`BaseDocument`
  is explicitly "a flexible headless DOM, designed to be embedded in and driven by
  external code"** — build/mutate DOM in Rust, run style+layout, read box geometry
  from Taffy. **Runs no JS.** **pre-alpha.** License **MIT/Apache** *but pulls in
  Stylo = **MPL-2.0*** (file-level copyleft). This is the engine we already have in
  wasm.
- **Stylo** (Firefox/Servo CSS engine, **MPL-2.0**), **Taffy** (flex/grid/block
  layout, **MIT**, used by Servo/Bevy/Zed/Blitz), **html5ever** (**MIT/Apache**) —
  all standalone-reusable. Servo's own `layout` crate is **not** cleanly
  extractable; Taffy is the practical embeddable layout choice.
- **Ladybird LibWeb** (C++, **BSD-2**) — full engine + own JS (LibJS), but tightly
  coupled to LibCore/LibGfx/LibIPC + multiprocess; **no embedding API**, pre-alpha.
  **Not realistically embeddable** (fork-and-carry-the-tree only).

**JS-implemented DOMs (run inside the JS engine; no native DOM):**

| Lib | License | Native deps | Geometry | Notes |
|---|---|---|---|---|
| jsdom | MIT | optional canvas | **stubbed → 0** | most spec-complete, heaviest, least wasm-friendly |
| **happy-dom** | MIT | **none** | **stubbed → 0** | 5–10× faster than jsdom; Custom Elements/Shadow DOM/MutationObserver |
| linkedom | ISC | **none** | **none** | fastest/lightest; already targets Deno/Workers; weak events |

All three return **zeros** for `getBoundingClientRect`/`offsetWidth/Top` — none
compute layout. The zero-native-dep ones (happy-dom, linkedom) can plausibly run
**inside StarlingMonkey** (binding blocker gone; linkedom's Deno/Worker targeting
is strong evidence it runs in WinterCG-class hosts). Parse/mutate/serialize works
in-wasm; **layout/geometry stays unavailable regardless of host.**

---

## (d) Ranked designs

### Design 1 — In-wasm StarlingMonkey + JS-DOM (happy-dom/linkedom), NO geometry
Page JS runs in our StarlingMonkey; a zero-native-dep JS-DOM gives it `document`.
- **Effort:** Low–Medium. Uses our existing engine; wire a JS-DOM + the Web APIs it
  touches; expose a CDP-ish or direct automation surface.
- **Risk:** Low technically. **Hard ceiling: no real layout/geometry** —
  `getBoundingClientRect` etc. return 0. Fine for DOM-state automation, scraping,
  form-fill, text/Markdown extraction (the *actual Lightpanda use case*). Bad for
  anything pixel/coordinate-driven (visual agent clicks by geometry).
- **License:** all permissive (MIT/ISC/Apache + our StarlingMonkey).

### Design 2 — In-wasm StarlingMonkey (JS-DOM) + delegate layout to our wasm Blitz
The proposed "Lightpanda-in-wasm". JS-DOM authoritative for the page's JS; mirror
the tree into Blitz `BaseDocument` for real geometry.
- **Effort:** **High.** You must mirror **every** DOM *and style* mutation
  (inline style, class, stylesheet edits, `:hover`/`:state()`) from the JS heap
  into Blitz, manage node identity across two heaps, and force a synchronous flush
  + read-back on **every** geometry call.
- **Risk:** **High — fights the nature of layout.** `getBoundingClientRect` is
  synchronous and forces **global** layout (one change moves the whole tree), so
  you can't sync just the changed node; real browsers avoid this by keeping
  DOM+layout co-resident with **direct pointers**. This re-creates exactly the
  V8↔Zig↔C friction Lightpanda **deliberately deleted** — across a *worse* boundary
  (wasm heap ↔ native heap). Lightpanda collapsing two *native* layers bought only
  single-digit %; splitting DOM (JS) from layout (native) goes the opposite way.
  Read-write-read layout-thrash loops (which these very APIs cause) destroy the
  only advantage the JS-DOM had. **Not recommended as the primary path.**
- **License:** Blitz inherits **Stylo MPL-2.0** (file-level copyleft — trackable).

### Design 3 — Native Zig browser: Kiesel + lexbor, brokered as a host service
The all-Zig Lightpanda-without-V8.
- **Effort:** **Very high** + **blocked**: Kiesel is ~59% test262, can't reliably
  run a transpiled React bundle, and has no DOM-binding layer. You'd also build the
  lexbor↔Kiesel WebIDL binding generator and a layout engine (lexbor has none).
- **Risk:** **Very high.** Bet on an early hobby engine maturing. Native, so it's a
  host-brokered service (BRIDGE wall), not in-wasm.
- **License:** lexbor Apache-2.0, Kiesel permissive — clean, if it existed.

### Design 4 — Native SpiderMonkey (or JSC) + lexbor/Blitz, brokered host service
The realistic *native* non-V8 browser: a production engine + native DOM/layout.
- **Effort:** **High** (heavy SpiderMonkey embed; write the WebIDL→SpiderMonkey
  binding generator; pair lexbor DOM with Blitz/Taffy layout, or drive Blitz
  `BaseDocument` directly).
- **Risk:** **Medium.** Engine is proven (Firefox/Servo); the work is binding +
  integration, not research. This is genuinely "Lightpanda's architecture without
  V8" — swap V8→SpiderMonkey, keep native DOM+layout co-resident.
- **License:** SpiderMonkey **MPL-2.0**, lexbor Apache, Blitz/Stylo MPL — all
  copyleft-but-permissive-enough (no AGPL).

### Design 5 — Reuse Lightpanda's `zigdom` + CDP, swap V8→SpiderMonkey
- **Effort:** **High** + **AGPL liability.** Rewrite `zig-js-runtime`'s comptime
  binding against SpiderMonkey's embedding API; keep `zigdom` + CDP server.
- **Risk:** Medium-technical, **high-legal** (AGPL-3.0 + CLA on the browser repo).
  You'd still have no layout (Lightpanda has none). **Not recommended** — the
  copyleft + bridge-rewrite cost exceeds building Design 4 clean.

---

## The single best near-term and long-term bets

**Best near-term bet → Design 1 (StarlingMonkey + JS-DOM, no geometry).**
It reuses everything we already have (StarlingMonkey eval host, fetch/streams/
crypto), is all-permissive, low-risk, and **covers the real Lightpanda use case**:
DOM-state automation, scraping, form-fill, and text/Markdown extraction for agents.
Use **happy-dom** (zero native deps, Custom Elements + Shadow DOM + MutationObserver,
5–10× faster than jsdom) inside StarlingMonkey; **linkedom** if we need it lighter.
Accept that `getBoundingClientRect` returns 0 — agents act on DOM structure/text,
not pixel coordinates. Ship this; it's weeks, not quarters.

**Best long-term bet → Design 4 (native SpiderMonkey + native co-resident DOM+
layout, host-brokered).** When agents genuinely need real geometry/visual grounding,
the only honest architecture is the browser architecture: DOM and layout
**co-resident** under one engine (the Servo/Blitz/Lightpanda model), with a real,
production non-V8 engine (SpiderMonkey) bound to it. Brokered as a host service
behind the Dock (BRIDGE wall), not in-wasm. Pair SpiderMonkey with **Blitz
`BaseDocument`** (purpose-built to be driven externally; gives us Stylo+Taffy real
layout) rather than splitting DOM-in-JS from layout-in-native.

**Explicitly do NOT pursue Design 2** as the primary path: a JS-DOM in wasm +
delegated native layout re-introduces, across a worse boundary, exactly the
two-sources-of-truth / forced-global-reflow friction that Lightpanda deleted for a
single-digit-% gain. It's the architecture the evidence most strongly warns against.

---

## Sources

Lightpanda: [browser repo](https://github.com/lightpanda-io/browser) (AGPL-3.0) ·
[why build a new browser (V8 choice)](https://lightpanda.io/blog/posts/why-build-a-new-browser) ·
[migrating our DOM to Zig](https://lightpanda.io/blog/posts/migrating-our-dom-to-zig) ·
[why Zig](https://lightpanda.io/blog/posts/why-we-built-lightpanda-in-zig) ·
[zig-v8-fork](https://github.com/lightpanda-io/zig-v8-fork) (MIT) ·
[zig-js-runtime](https://github.com/lightpanda-io/zig-js-runtime) ·
[libdom fork](https://github.com/lightpanda-io/libdom) ·
[HN](https://news.ycombinator.com/item?id=46586179)

Engines: [StarlingMonkey](https://github.com/bytecodealliance/StarlingMonkey) /
[docs](https://bytecodealliance.github.io/StarlingMonkey/) ·
[ComponentizeJS](https://github.com/bytecodealliance/ComponentizeJS) ·
[JSC.js](https://github.com/mbbill/JSC.js) ·
[Kiesel](https://codeberg.org/kiesel-js/kiesel) / [devlog](https://linus.dev/posts/kiesel-devlog-1/) ·
[Nova](https://github.com/trynova/nova) / [trynova.dev](https://trynova.dev/) /
[NLnet](https://nlnet.nl/project/Nova/) ·
[Boa](https://github.com/boa-dev/boa) / [boajs.dev](https://boajs.dev/) ·
[quickjs-ng](https://github.com/quickjs-ng/quickjs) · [test262.fyi](https://test262.fyi)

DOM/layout: [lexbor](https://github.com/lexbor/lexbor) (Apache-2.0) ·
Netsurf [libhubbub](https://www.netsurf-browser.org/projects/hubbub/) /
[libdom](https://www.netsurf-browser.org/projects/libdom/) /
[libcss](https://www.netsurf-browser.org/projects/libcss/) (MIT) ·
[Blitz](https://github.com/DioxusLabs/blitz) / [blitz-dom docs](https://docs.rs/blitz-dom) ·
[Stylo](https://github.com/servo/stylo) (MPL-2.0) ·
[Taffy](https://github.com/DioxusLabs/taffy) (MIT) ·
[html5ever](https://github.com/servo/html5ever) ·
[Ladybird](https://github.com/LadybirdBrowser/ladybird) (BSD-2) ·
[jsdom](https://github.com/jsdom/jsdom) · [happy-dom](https://github.com/capricorn86/happy-dom) ·
[linkedom](https://github.com/WebReflection/linkedom) ·
[V8 Fast API calls](https://v8.dev/blog/adaptor-frame)
