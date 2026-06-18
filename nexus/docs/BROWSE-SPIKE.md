# Browse spike — Blitz renders the web IN wasmtime (no Chromium, no native)

**The question that hinged everything:** can an agent get real (Playwright-level) web rendering
*inside* the wasmtime sandbox — no bundled Chromium, no host-native browser (not even OS WebKit),
no GPU?

**Tier 1 verdict: PROVEN for rendering.** A real fetched webpage (example.com) was rendered to a
pixel-perfect PNG screenshot **entirely inside wasmtime** by Blitz (Stylo CSS + Taffy layout +
Parley text + Vello-CPU paint) — heading, body text, the styled blue link, correct layout/fonts.
No Chromium, no native code, no GPU. Proof: `/tmp/blitz-spike.png` (1200×800).

## How

- Engine: `runtime/wavelet/crates/wavelet-render-core` (already in-repo for wavelet video; Blitz +
  Stylo + Vello, compiles to `wasm32-wasip1` with zero Stylo source patches).
- New bin: `src/bin/render_page.rs` — reads an arbitrary fetched HTML file (WASI fs) → `render_frame`
  → PNG. Built with `cargo build --target wasm32-wasip1 --release --bin render_page` →
  `render_page.wasm` (~12 MB artifact, like coreutils — prebuilt host-side, RUN in-sandbox).
- Flow: `fetch <url>` (host-brokered, SSRF-safe) → HTML to the VFS → `wasmtime run render_page.wasm`
  → PNG screenshot in `/work`. The fetch is brokered (wasm has no sockets); the RENDER is in-wasm.

## What this means

We need **neither** Chromium **nor** OS WebKit. The render half of a browser runs in wasmtime today.

## Next (in order)

1. **Rendered text extraction** — agents want text more than pixels. Add a Blitz DOM walk (visible
   text, CSS-aware: skip display:none/script/style) → `render`/`scrape` returns clean text. (The
   render-core lib exposes pixels only today; this needs a small DOM-walk fn against blitz-dom.)
2. **Wire `Nexus.Browse.Blitz` provider** (`:render`, `:screenshot`) + bash builtins (`render <url>`,
   `screenshot <url>`, upgrade `scrape`). The `Nexus.Browse` seam + `Http` provider are in place.
3. **Tier 2 (the dream): JS execution** — wire a wasm JS engine (StarlingMonkey / QuickJS, both
   in-repo) to the Blitz DOM so the page's own JS runs → Playwright-level, still 100% in wasmtime.
   Both halves already run in wasm; this is an integration, not a feasibility, question.

## Honest caveats

- Blitz renders HTML/CSS, not JS — SPAs won't populate until Tier 2.
- Subresources (images/external CSS) need fetching/inlining (render-core uses a file/data: net
  provider today, no live http); for text scraping this matters little, for faithful screenshots more.
- Real-world malformed HTML hardening (render-core was built for our own clean compositions).
