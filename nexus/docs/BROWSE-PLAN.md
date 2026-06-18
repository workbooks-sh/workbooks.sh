# In-wasm browser — the full build (the contract)

Proven: Blitz renders arbitrary HTML to a pixel-perfect PNG inside wasmtime (example.com). Empirical
gaps on real brand pages, in forced build order:

1. **Subresources crash** — external `<link href>`/`<img src>` → Blitz panics (no base_url, no net
   provider; render-core was built for self-contained compositions).
2. **JS-rendered SPAs are blank** — Stripe/Vercel/Nike have no content without JS.
3. **TLS fingerprinting** — anti-bot (Cloudflare) blocks non-browser TLS.

Goal: real renders of varying difficulty, fully in-wasm where possible (no Chromium, no OS WebKit).
Grind to completion; commit each win; honest caveats; keep the suite green.

## Layer 1 — subresource pipeline + crash-hardening (unlocks SSR/content pages)
- Harden the render-core net provider: a missing/unfetchable/http resource must NOT panic — return
  empty, render without it. (Fix `blitz-dom` resolve panic via base_url + a non-fatal provider.)
- `render_page` takes a `base_url` so relative URLs resolve.
- Host-side **freeze** (Elixir): fetch HTML + its CSS/images (brokered), inline CSS into `<style>`,
  images as `data:` URIs → self-contained HTML → render in-wasm.
- DONE WHEN: Wikipedia, Hacker News, a news article, an SSR brand page render with real content.

## Layer 2 — TLS fingerprinting (unlocks anti-bot sites)
- A host-side browser-TLS fetcher (Chrome JA3/JA4 + HTTP/2 fingerprint) behind `Nexus.Dock.fetch` /
  a `Nexus.Browse` provider — a focused TLS client (rquest/curl-impersonate class), NOT a browser.
  Consistent with fetch already being brokered.
- DONE WHEN: a Cloudflare-protected page fetches 200 + renders.

## Layer 3 — JS rendering (the dream: SPAs, Playwright-level, in-wasm)
- Wire a wasm JS engine (StarlingMonkey or QuickJS — both in-repo) to the Blitz DOM: expose
  document/window/element APIs, run the page's `<script>`s, mutate the DOM, re-layout, re-render.
- Incremental: (a) run inline scripts that touch the DOM; (b) fetch+run external scripts; (c) a
  micro-event-loop (timers, basic fetch) so frameworks hydrate; (d) wait-for-idle then snapshot.
- DONE WHEN: a real SPA (Stripe/Vercel) renders populated content, in wasmtime.

## Wiring (throughout)
- `Nexus.Browse.Blitz` provider (`:render` text, `:screenshot`) over the render wasm.
- A DOM text-walk in render-core → `render`/`scrape` returns clean rendered text (agents want text).
- bash builtins: `render <url>`, `screenshot <url>`, `scrape <url>` (render-then-text), `search`.

## Done when
An agent can `render`/`screenshot`/`scrape` real pages of varying difficulty — static, SSR, anti-bot,
and SPA — with the render running in wasmtime. Tested, demoed, documented, suite green, pushed.
