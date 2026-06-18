# Greenfield browser — StarlingMonkey + JS-DOM + Blitz (the contract)

The research bet: swap Boa → **StarlingMonkey** (real SpiderMonkey-in-wasm) and give it a **JS DOM**
(linkedom/happy-dom, run inside the JS engine), delegating **layout/paint** to our in-wasm **Blitz**.
This dodges Boa's two walls — no capacity limit (real engine), and the DOM is JS (not 539 hand-bound
Rust interfaces). All in wasmtime, no Chromium, no V8.

## Why this beats Boa
- Boa: crashes on big bundles, no event loop, missing APIs → can't run framework JS.
- StarlingMonkey: full SpiderMonkey + WHATWG platform (WebCrypto/fetch/streams) + a real **event
  loop** (Promises/async settle) → runs React's JS. **Proven running in nexus** (`Nexus.JsEngine`).

## Steps
- ✅ **G0** StarlingMonkey eval in nexus (`Nexus.JsEngine.eval` → real JS: 6*7, map, JSON, Set).
- ◻ **G1** A JS DOM in the engine — bundle **linkedom** (pure-JS DOM, server-grade) into one blob
  (esbuild), eval `parseHTML(html)` → a `document`; mutate via real DOM APIs → serialize back to HTML.
  DONE WHEN: a script using `document.createElement`/`querySelector`/`innerHTML` builds a DOM in
  StarlingMonkey and we serialize the result.
- ◻ **G2** Run a page's JS — inject the page HTML + its (inlined) scripts; run them against the
  linkedom `document`; await the event loop (Promises/timers) to settle; serialize the hydrated DOM.
  DONE WHEN: a JS-built page (that crashed Boa) produces populated serialized HTML.
- ◻ **G3** Bridge to Blitz — feed the hydrated serialized HTML to the Blitz render wasm → text +
  screenshot. The JS runs in StarlingMonkey; layout/paint in Blitz; host orchestrates (two wasm
  modules). DONE WHEN: a real CSR SPA renders populated content + screenshot, in wasmtime.
- ◻ **G4** Computer-use geometry — clickable element bounds (Blitz layout) + the hydrated DOM →
  action targets for the agent / vision loop. Wire into `Nexus.Browse` as the JS-render provider.
- ◻ **G5** Harden — wall-clock bound, fetch brokering for the JS engine's `fetch`, fallback to the
  Boa/SSR path. Make it the default render when a page needs JS.

## Done when
A real client-only SPA (that Boa couldn't run) renders populated content + screenshot via
StarlingMonkey-DOM + Blitz, in wasmtime, wired into the canonical `Nexus.Browse` capability.
