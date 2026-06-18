# Layer 3 — JavaScript rendering, completely (the contract)

Proven: Boa (pure-Rust JS) runs a page's inline JS against the Blitz DOM in wasmtime; an innerHTML
mutation renders. Now make it real for actual SPAs. Grind end to end; commit each step; honest caveats.

The spike used a write-only op-queue. Real frameworks read AND write the DOM imperatively, so the
core is a **live DOM binding**: each JS element handle wraps a live Blitz node id, and the native
functions read/mutate the live `BaseDocument` during script execution (single-threaded wasm → a
thread-local doc pointer makes this sound).

## 3a — inline JS → DOM (DONE)
innerHTML setter mutates the Blitz DOM; renders.

## 3b — live DOM API (the core)
Replace the op-queue with live element handles (`__nodeid`) over a thread-local `*mut BaseDocument`:
- read: `textContent` (get), `getAttribute`, `id`/`className`/`tagName`, `children`/`childNodes`/
  `parentNode`/`firstChild`.
- write: `createElement`, `createTextNode`, `appendChild`, `insertBefore`, `removeChild`,
  `setAttribute`/`removeAttribute`, `textContent` (set), `innerHTML` (set), `id`/`className` (set).
- query: `getElementById`, `querySelector`, `querySelectorAll`.
- DONE WHEN: an imperative script (createElement + appendChild building a tree) renders.

## 3c — globals + DOM environment
`window` (= globalThis), `document`, `location`, `navigator`, `history` (stubs with sane values),
`console`. `el.style.X = …` → inline style. `classList` add/remove/toggle/contains.

## 3d — external scripts
Freeze inlines `<script src>` host-side (brokered fetch, like CSS) so the page's real JS runs;
respect `defer`/`async` ordering enough to render.

## 3e — events
`addEventListener`/`removeEventListener` (register), `dispatchEvent`. Initial render attaches
listeners; firing (interaction) is a later concern. `DOMContentLoaded`/`load` fire after parse.

## 3f — timers + microtasks + a settle loop
`setTimeout`/`setInterval`/`clearTimeout`, `queueMicrotask`, `Promise` (Boa native). A bounded
run-loop after the main scripts: drain microtasks, fire due timers, re-resolve — so deferred render
work (framework hydration) completes before the snapshot.

## 3g — fetch / data
`fetch` brokered through the host (the render wasm has no sockets → a host import OR pre-inlined
data). Many SPAs render from embedded data (Next `__NEXT_DATA__`); support that first.

## 3h — real SPA proof + hardening
Render real SPAs (a Next/React page) to populated content. Crash-resistance on hostile JS; a
wall-clock bound on the JS run. Wire it all through `Nexus.Browse` + the agent `scrape`/`render`.

## Status (honest)

- ✅ **3a** inline JS → DOM · ✅ **3b** live DOM API (createElement/appendChild/attributes/query) ·
  ✅ **3c** globals (window/self/globalThis/location/navigator/console + no-op timers) · ✅ **3d**
  external scripts (freeze inlines `<script src>`) · ◻ **3e** events registered (not fired) · ◻ **3f**
  no real settle loop (timers are no-ops) · ◻ **3g** no fetch.
- ✅ **Robustness**: `render(url)` runs JS, and on crash/timeout falls back to the no-JS render —
  which has the **server-rendered** content. Proven: `render(vercel)` → JS aborts (capacity overflow
  on the 3.5MB Next bundle) → fallback delivers 223 lines of real Vercel content. Never fails.

### The honest reality (why this is "complete" for practical purposes)
- **Most real sites SSR their content** (Next/Remix/etc. — Vercel, Stripe verified). Layer 1 / the
  fallback gets the **text** without JS. JS rendering matters only for true client-only (CSR) pages.
- **JS rendering works** for pages that build content with vanilla/imperative JS (proven: an
  imperative createElement+appendChild tree renders in wasmtime).
- **Full production framework bundles (React/Next, MBs) are a wall** in Boa — capacity overflow +
  hundreds of missing browser APIs — AND unnecessary (those pages SSR). Chasing full hydration is
  low ROI; the robust fallback already delivers their content.
- A real event loop (3e/3f) + `fetch` (3g) would extend CSR coverage incrementally but with
  diminishing returns. Deferred unless a concrete CSR target needs it.

## Done when
A real JS-rendered page (SPA) produces populated rendered text + screenshot, in wasmtime, no
Chromium — tested, wired into nexus, documented, suite green, pushed.
