# Closing the real-browser fidelity gap — in-wasm only (no Chromium, no external infra)

**Question.** How do we bring nexus's in-wasm browser (Blitz layout/paint +
StarlingMonkey running a JS-DOM) to a *comparable* (not pixel-perfect) fidelity vs
hosted Chromium — **without** adding a real browser or external infra (no Chromium, no
CDP, no V8, no residential proxies)?

**Architecture (the constraint).** Pages render entirely in wasmtime: **Blitz**
(blitz-dom + blitz-html + Stylo CSS + Taffy layout + Parley text + Vello-CPU paint) for
layout/paint, **StarlingMonkey** (SpiderMonkey→wasm; real event loop + fetch + WebCrypto +
streams) running **linkedom** (bundled, pure-JS DOM) for the page's own JS. Proven:
linkedom runs in StarlingMonkey, a page's JS hydrates a real `document`, the loop settles,
we serialize the hydrated DOM → Blitz renders it. Host-brokered fetch (no sockets in wasip1).

> Date 2026-06-18. Branch `work-html-format`. Research doc — no code. Builds on
> `TIER2-RESEARCH.md`, `LIGHTPANDA-RESEARCH.md`, `BROWSE-SPIKE.md`,
> `COMPUTER-USE-COMPARISON.md`. New contribution: the **one-way, staged
> geometry-feedback bridge** (explicitly distinct from the *live two-way* bridge that
> `LIGHTPANDA-RESEARCH.md` Design 2 warned against), grounded in what Blitz/Taffy
> actually expose. Proven vs speculative flagged inline; primary sources at end.

---

## (a) The fidelity ceiling — what breaks and why

The gap vs Chromium is **not** the JS engine (StarlingMonkey runs React's JS) and **not**
paint (Blitz paints; agents rarely need pixels). It is **two things**:

### 1. Geometry is zero. (The dominant break.)
Every pure-JS DOM — linkedom, happy-dom, jsdom — returns **0** for all layout queries,
because **none of them computes layout**. This is structural, not a bug: jsdom's
`getBoundingClientRect` has been open since **2013, explicitly "blocked on implementing a
layout engine"** ([jsdom#3621](https://github.com/jsdom/jsdom/issues/3621),
[#653](https://github.com/jsdom/jsdom/issues/653)). The affected surface:

| API | What returns wrong | Who depends on it |
|---|---|---|
| `getBoundingClientRect()` / `getClientRects()` | DOMRect of all-zeros | virtualized lists (react-window/virtuoso), tooltips/popovers (Floating UI, Radix, Headless UI), drag-drop, charts |
| `offsetWidth/Height/Top/Left`, `clientWidth/Height`, `scrollWidth/Height` | 0 | responsive layout JS, carousels, masonry, "read size then style" patterns |
| `IntersectionObserver` | stub; **never fires** (or fires with zero rects) | lazy-load images, infinite scroll, fade-in-on-scroll, "load more" sentinels, ad/impression gating |
| `ResizeObserver` | absent / stub; never fires | responsive charts, auto-resizing textareas, container queries in JS |
| `getComputedStyle()` | returns declared values only, **no resolved/used values** (no resolved px, no inherited cascade for layout) | anything measuring computed size/position |
| `matchMedia()` | **not implemented** in happy-dom or linkedom | responsive component branches, dark-mode JS, `prefers-*` |
| `scrollTo` / `scrollIntoView` / `scrollY` | no-op / 0 | scroll-spy navs, "scroll to section", restoration |
| `element.scrollHeight > clientHeight` overflow checks | both 0 → false | "show more" expanders, sticky logic |

**Why it breaks hydration specifically.** React/Vue/Svelte *render* fine without geometry
(that's SSR/`renderToString`, the linkedom happy path). They **break after hydration**:
effect hooks fire (`useLayoutEffect`/`onMount`), call `getBoundingClientRect`, get
`{0,0,0,0}`, and the component either collapses (virtualized list renders 0 rows because
viewport height is 0), throws, or silently shows nothing (IntersectionObserver-gated
content never un-gates → empty body). **This is the same failure class Lightpanda hits
even with real V8** — its documented Stripe-docs failure was missing APIs / zero-geometry
behaviors, not slow JS. So even a *real engine* without layout has our exact ceiling.

### 2. Web-API breadth (the long tail) — secondary but real.
Beyond geometry, linkedom is deliberately minimal: **no faithful event propagation, weak
`MutationObserver`, no Custom Elements lifecycle, no Shadow DOM** in the way frameworks
expect. happy-dom covers far more (Custom Elements, Declarative Shadow DOM,
MutationObserver, TreeWalker, real event bubbling) at ~7.5× jsdom's speed
([happy-dom](https://github.com/capricorn86/happy-dom)). This is the breadth axis, and
it's **stubbable** incrementally — each missing API is a finite shim, not a research
problem. The geometry axis is the one that needs a real layout engine, which is exactly
the thing we uniquely already have in-wasm (Blitz/Taffy).

### Proven vs fundamental (the triage)
- **Stubbable cheaply (no layout needed):** `matchMedia` (fixed viewport + media-feature
  table), `requestAnimationFrame`/`cancelAnimationFrame` (→ microtask/`setTimeout`),
  `history`/`location` (in-memory), `localStorage`/`sessionStorage`, `structuredClone`,
  `crypto` (StarlingMonkey already has WebCrypto), `fetch`/`XHR` (broker), `customElements`
  + Shadow DOM (adopt happy-dom which has them).
- **Needs real geometry → only solvable via the Blitz bridge (b):** `getBoundingClientRect`,
  `offsetWidth/Height`, `client/scrollWidth/Height`, `IntersectionObserver`,
  `ResizeObserver`, `getComputedStyle` (used values), `scrollIntoView`, `elementFromPoint`.
- **Genuinely fundamental / out of scope (accept the gap):** `<canvas>` 2D/WebGL pixel
  content (no DOM nodes inside), WebRTC/media, service workers, `WebGPU`. These are the
  hard ~10% visual tail; comparable-not-perfect explicitly excludes them.

### Library choice for in-engine use
| | linkedom (current) | happy-dom | jsdom |
|---|---|---|---|
| Size / parse speed | smallest, fastest | mid, ~7.5× jsdom | largest, slowest |
| Native deps | none (wasm-safe) | **none (wasm-safe)** | optional canvas (wasm-hostile) |
| Events / MutationObserver | weak | **faithful** | faithful |
| Custom Elements / Shadow DOM | partial | **yes** | yes |
| Geometry | **0** | **0** | **0** (and least wasm-friendly) |
| Hydration-grade? | serializer only | **yes** | yes |

**Recommendation: migrate the JS-DOM from linkedom → happy-dom.** linkedom is a
*serializer* ("linkedom runs React" is true only for `renderToString`, not a hydrated
interactive app); happy-dom is the lightest *hydration-grade* DOM with zero native deps,
so it's the one that runs in StarlingMonkey. Keep linkedom as the fast SSR-only path.
All three still return zero geometry — that's (b).
([pkgpulse compare](https://www.pkgpulse.com/guides/happy-dom-vs-jsdom-vs-linkedom-dom-simulation-2026))

---

## (b) The geometry-feedback bridge — viable, and it dodges the prior warning

**The prior `LIGHTPANDA-RESEARCH.md` Design 2 warning was specifically about a *live,
two-way, synchronous* bridge** — where every `getBoundingClientRect` call forces a
*global synchronous reflow* across the JS-heap↔native-heap boundary, recreating the
V8↔Zig↔C friction Lightpanda deleted, and where read-write-read layout-thrash loops
destroy the perf win. **That warning stands for the live design and we keep it.**

The question here is a *different shape*: a **one-way, staged, batched** measure pass —
**run JS → quiesce → serialize DOM+styles once → Blitz computes layout once → inject the
computed boxes back into the JS-DOM as cached values → re-run the now-geometry-dependent
JS**. This is **viable**, and the warning does **not** apply, for three reasons:

1. **It's one-way per stage.** Blitz is the measurement oracle, never a live mirror. We
   don't keep two heaps in sync on every mutation; we snapshot at a barrier. No node-identity
   tracking across heaps on the hot path, no forced *global* reflow per `gBCR` call — the
   reflow happens **once per stage**, amortized over the whole tree.
2. **`gBCR` reads from a cache, synchronously, with no cross-boundary call.** After a
   measure pass we populate each element's cached rect *in JS*. The page's synchronous
   `getBoundingClientRect()` returns the cached box instantly — exactly how a real browser
   serves it from the last layout. No host call on the read path = no thrash.
3. **Blitz is purpose-built for exactly this.** `BaseDocument` is documented as *"a flexible
   headless DOM, designed to be embedded in and driven by external code."* It exposes the
   full mutate→resolve→read cycle we need (verified against docs.rs):
   - **Mutate:** `mutate() -> DocumentMutator`, `create_node`, `set_style_property`,
     `remove_style_property`, `set_attribute`.
   - **Resolve (the batched relayout):** `resolve(time)` = *"Restyle the tree and then
     relayout it"*; underneath, `resolve_layout()` transfers Stylo styles into Taffy and
     `LayoutPartialTree`/`LayoutFlexboxContainer`/`LayoutGridContainer` run the layout.
   - **Read per-node box:** each node carries its computed **Taffy `Layout { location:
     Point<f32>, size: Size<f32> }`** (x/y/width/height) — Blitz stores `final_layout` per
     node, same pattern as Taffy's `final_layouts: Vec<Layout>`. Plus `hit(x, y) ->
     HitResult` for `elementFromPoint`/click hit-testing, which *proves* the layout tree is
     queryable by coordinate. ([blitz-dom](https://lib.rs/crates/blitz-dom),
     [BaseDocument](https://docs.rs/blitz-dom), [Taffy `Layout`](https://docs.rs/taffy))

**So the data we need exists and is readable**: per-node box (for `gBCR`/`offset*`), node
stacking/visibility (for IntersectionObserver), resolved used-values (for
`getComputedStyle`). The bridge is **serialize tree+styles → one Blitz `resolve()` →
walk nodes reading `final_layout` keyed by a stable id we assigned at serialize time →
ship a `{nodeId → DOMRect}` table back into the JS-DOM**.

### The staged pipeline (concrete)
```
Stage 0  fetch (broker) → HTML → StarlingMonkey + happy-dom: parse, run scripts in
         DOMContentLoaded order, await event loop quiesce (timers/microtasks drained).
Stage 1  MEASURE PASS: serialize current DOM + inline/used styles → Blitz BaseDocument;
         assign each element a stable data-blitz-id; resolve() once; walk nodes →
         build {id → {x,y,w,h, computedStyle subset}}.  [one-way, one reflow]
Stage 2  INJECT: populate happy-dom caches — element.__rect, offsetWidth/Height from the
         table; fire IntersectionObserver/ResizeObserver callbacks computed from the
         boxes vs the fixed viewport; getBoundingClientRect/getComputedStyle read cache.
Stage 3  RE-RUN: let the geometry-dependent JS run (layout effects, observers). If it
         mutated the DOM materially, loop to Stage 1 (bounded N, typically 1–2 passes —
         same convergence a browser does across animation frames).
Stage 4  Blitz paints the final tree (existing path) + emit DOM/a11y-tree/box table for
         the agent.
```

**Convergence is bounded and natural.** Real browsers already settle layout over a few
frames; React's `useLayoutEffect` is designed to run, measure, and possibly re-render
*once* before paint. A 1–3 pass fixpoint covers the overwhelming majority; cap N and accept
non-convergence on pathological measure-loops (rare, and Chromium throttles those too).

**This is the moat.** jsdom has wanted this since 2013 and never got it because a JS-DOM
has no layout engine. We *have* one, in-wasm, already (Blitz/Taffy). **"In-wasm JS-DOM →
native Rust layout, staged" has no shipped prior art** (confirmed across jsdom#3621/#653,
happy-dom, linkedom, deno_dom, Lightpanda — none compute layout; Lightpanda explicitly
drops it). If we build it, we own a capability nobody else has.

### Honest risks (what to watch — proven concerns, not blockers)
- **Style fidelity at the serialize boundary.** Blitz must see the *same* cascade the JS
  mutated (inline styles, class toggles, dynamically inserted `<style>`). Serialize
  *resolved* inline styles + the active stylesheet set, not just the static HTML. This is
  the real engineering surface; it's tractable (Stylo is the cascade).
- **Pseudo-class / interaction states** (`:hover`, `:focus`, `:state()`) need the agent's
  intended state fed into the measure pass — fine for a deterministic agent driver.
- **Marshalling cost** of serialize+inject per pass. Mitigate: only re-serialize *dirty*
  subtrees on later passes (happy-dom MutationObserver tells us what changed) — still
  one-way, just incremental input, not a live mirror.
- **No JIT** (orthogonal to the bridge): StarlingMonkey is interpreter-speed; heavy bundles
  run but slowly (`weval` AOT ~2–5×, flag-gated). The bridge doesn't change this; it's the
  separate perf ceiling from `TIER2-RESEARCH.md` §2.

**Verdict: VIABLE and recommended.** The staged one-way bridge is materially different
from — and not refuted by — the prior two-way warning. It is the single highest-leverage
in-wasm capability we can build, and Blitz already exposes the exact primitives.

---

## (c) Ranked in-wasm-only capability adds (leverage × effort)

Ranked by leverage/effort. All stay in-wasm or host-brokered.

| # | Capability | Leverage | Effort | Notes |
|---|---|---|---|---|
| **1** | **happy-dom swap** (linkedom→happy-dom for the interactive path) | **High** | **Low** | Unlocks faithful events, Custom Elements, Shadow DOM, MutationObserver — the breadth floor hydration needs. Drop-in; keep linkedom for SSR-only. Precondition for the bridge. |
| **2** | **Cheap API shims** into StarlingMonkey+DOM | **High** | **Low** | `matchMedia` (fixed viewport), `rAF`→timer, `history`/`location`, `localStorage`, `structuredClone`, `scrollTo` (no-op + state). Each kills a class of hydration throws. No layout needed. |
| **3** | **Geometry-feedback bridge (b)** — staged Blitz measure → inject `gBCR`/`offset*`/`getComputedStyle` used-values | **Very High** | **High** | The moat. Removes the dominant break. Build incrementally: `gBCR`+`offset*` first (covers most), observers next. |
| **4** | **IntersectionObserver + ResizeObserver, computed from the box table** | **High** | **Med** | Once #3 gives boxes, both observers are pure JS over `{box vs viewport}`. Unlocks lazy-load / infinite-scroll / impression-gated content → fixes "empty body" SPAs. |
| **5** | **fetch/XHR brokering completeness** for data-loading SPAs | **High** | **Low–Med** | Already brokered; ensure XHR, `fetch` with credentials/headers, and JSON endpoints populate so data-driven SPAs render real content. Pure plumbing. |
| **6** | **Script ordering & module graph** — `DOMContentLoaded`/`load` ordering, `<script type=module>`, dynamic `import()`, `import.meta` | **High** | **Med** | StarlingMonkey supports ESM; wire deferred/async/module ordering + a broker-backed module loader so bundlers' code-splitting + dynamic imports resolve. Without it, split SPAs stall. |
| **7** | **a11y-tree + clickable-box export** for the agent | **High** | **Low** | Post-#3, emit DOM + a11y tree + per-element box table → the cheapest strong agent representation (TIER2 §6). We're uniquely positioned because we have layout. |
| **8** | **customElements/Shadow DOM** depth (web-component sites + our own work-\* kit — dogfood) | **Med** | **Low** | happy-dom gives the floor; verify our `work-*` Lit components hydrate in-engine. Direct dogfood win. |
| **9** | **wasm-in-page** (page ships its own `.wasm`) | **Low** | **Med** | StarlingMonkey can instantiate guest wasm; rare on the open web; defer. |
| **10** | **Event-loop faithfulness** (stack-switching/JSPI for true async ordering) | **Low–Med** | **High/blocked** | wasmtime stack-switching is experimental (x64-only). Current microtask/timer loop is adequate; don't block on this. |

---

## (d) The single highest-leverage next step

**Build the staged one-way geometry-feedback bridge (capability #3), on a happy-dom JS-DOM
(#1), starting with `getBoundingClientRect` + `offsetWidth/Height` served from a single
batched Blitz measure pass.**

Why this one:
- It removes the **dominant** fidelity break (zero geometry), which is *the* thing that
  collapses hydrated SPAs — and which even real-V8 Lightpanda cannot fix (it has no layout).
- It is the **only** in-wasm capability nobody else has or can easily get: a JS-DOM bridged
  to a real layout engine. jsdom has wanted exactly this since 2013 and is structurally
  blocked; we are structurally *unblocked* because Blitz/Taffy already run in our sandbox
  and `BaseDocument` is built to be driven externally (`mutate → resolve → read final_layout`).
- It respects the architecture: **one-way and staged**, so it does **not** reintroduce the
  two-way/global-reflow friction the prior research correctly warned against. Blitz is a
  measurement oracle invoked at a barrier, not a live mirror.
- Sequencing: do #1 (happy-dom) and #2 (cheap shims) first — they're days of work and
  unblock the bridge — then land `gBCR`/`offset*` (the 80% of geometry usage), then layer
  IntersectionObserver/ResizeObserver (#4) on top of the same box table. That ordering takes
  us from "SSR + light JS" to "comparable-to-Chromium on the structured/interactive
  majority," leaving only the genuine ~10% pixel tail (canvas/WebGL/media) out of scope —
  which is exactly the "comparable, not perfect" target.

**Floor stays free:** the existing CSS-only Blitz path remains the fast default for SSR
sites; the JS+bridge path is the fallback for client-rendered shells — same posture as
today, but the fallback now actually has geometry.

---

## Sources

Blitz / Taffy (the bridge primitives):
[blitz-dom (lib.rs)](https://lib.rs/crates/blitz-dom) ·
[BaseDocument (docs.rs)](https://docs.rs/blitz-dom) ·
[Blitz repo + HOWTO_WASM](https://github.com/DioxusLabs/blitz) ·
[Taffy `Layout`/`compute_layout`/`layout()`](https://docs.rs/taffy) ·
[Taffy repo](https://github.com/DioxusLabs/taffy) ·
[Blitz roadmap #119](https://github.com/DioxusLabs/blitz/issues/119)

The geometry ceiling (no JS-DOM has layout — the moat):
[jsdom#3621 — gBCR blocked on a layout engine](https://github.com/jsdom/jsdom/issues/3621) ·
[jsdom#653](https://github.com/jsdom/jsdom/issues/653) ·
[jsdom#1581](https://github.com/jsdom/jsdom/issues/1581) ·
[jsdom-testing-mocks (people mock gBCR because it returns 0)](https://www.npmjs.com/package/jsdom-testing-mocks)

JS-DOM comparison / missing APIs:
[happy-dom](https://github.com/capricorn86/happy-dom) ·
[linkedom](https://webreflection.medium.com/linkedom-a-jsdom-alternative-53dd8f699311) ·
[jsdom](https://github.com/jsdom/jsdom) ·
[happy-dom vs jsdom vs linkedom (2026)](https://www.pkgpulse.com/guides/happy-dom-vs-jsdom-vs-linkedom-dom-simulation-2026) ·
[matchMedia/ResizeObserver not implemented → must polyfill](https://www.pkgpulse.com/guides/happy-dom-vs-jsdom-2026)

Engine + prior-art context (in-repo): `nexus/docs/TIER2-RESEARCH.md`,
`nexus/docs/LIGHTPANDA-RESEARCH.md`, `nexus/docs/BROWSE-SPIKE.md`,
`nexus/docs/COMPUTER-USE-COMPARISON.md` ·
[StarlingMonkey](https://github.com/bytecodealliance/StarlingMonkey) ·
[Lightpanda (real V8, still no layout → same ceiling)](https://github.com/lightpanda-io/browser)
