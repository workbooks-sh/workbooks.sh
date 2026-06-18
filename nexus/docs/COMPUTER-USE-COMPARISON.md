# Where we stand vs Browser Use / Browserless / Kernel (computer-use only)

An honest capability comparison of nexus's **in-wasm** browse/computer-use against three external
browser microservices. The headline difference is architectural: **they are all hosted Chromium +
CDP** (a real browser in a container/VM per session). **We are not a browser** — we render with Blitz
(pure-Rust Stylo/Taffy/Vello) + run JS in StarlingMonkey, all inside wasmtime, in the Elixir process.
That one fact explains every win and every gap below.

## Table

| Axis | **nexus (ours)** | Browser Use | Browserless | Kernel |
|---|---|---|---|---|
| **Engine** | Blitz render + StarlingMonkey JS, **in-wasm, no browser** | Chromium/CDP | Chrome/WebKit/Firefox CDP | Sandboxed Chromium |
| **Action model** | **semantic by element number** + vision loop | **element index** + vision | none (you script Puppeteer/PW) | none (bring your agent) |
| **Agent brain** | ✅ multi-step loop (Tier-1 + Gemma vision) | ✅ the only other one with a brain | ❌ infra | ❌ infra |
| **Render/extract** | text + screenshot (CSS-aware); PDF/markdown = roadmap | screenshot + DOM + extract | `/content /screenshot /pdf /scrape` + BrowserQL | screenshot + MP4 replay |
| **JS-heavy SPA fidelity** | ⚠️ SSR + light JS (StarlingMonkey+linkedom fallback); **not full-browser** | ✅ real Chromium | ✅ real Chromium | ✅ real Chromium |
| **Anti-bot (stealth/CAPTCHA/proxy/TLS)** | ❌ **none** (brokered fetch only) | ✅ (cloud) | ✅ | ✅ (headful, strongest) |
| **Per-session cost** | **wasmtime instantiate (~ms), no container** | a Chromium process | a Chromium process | a Chromium sandbox (<30ms cold) |
| **Concurrency** | **many per BEAM node, in-process** | keep-alive sessions | 2–100 browsers/plan | autoscale pools |
| **Compute/step (measured)** | **Tier-1 ~633ms; vision ~2.9s (model-bound)** | not published | n/a (infra) | n/a (infra) |
| **Deploy** | **embedded in the runtime, zero external infra** | self-host lib or cloud | cloud + enterprise Docker | cloud only |
| **Billing axis** | our own compute | per cloud session | units (30s) + proxy/CAPTCHA | per active browser-second |
| **License** | ours | MIT lib / paid cloud | source-available / paid | proprietary SaaS |

## Where we genuinely win
- **No browser to host.** Every competitor spins a Chromium process/sandbox per session; we instantiate
  a wasm module in-process. That's why our per-step compute is sub-second and concurrency is "many per
  BEAM node" rather than "2–100 browsers per plan." For an Elixir server fanning out concurrent
  scrapes/agents, this is a structural cost advantage, not a tuning one.
- **Agent brain included, and it's the same model as the best of them.** Browser Use is the only
  external tool with its own agent loop, and its core trick — **act on indexed interactive elements** —
  is exactly our Tier-1 semantic model (`click <n>` / `fill`/`submit`), plus a vision loop. Browserless
  and Kernel ship *no* agent; you bring one.
- **Zero external dependency / egress.** No microservice, no API units, no per-browser-second meter, no
  data leaving the runtime. The render + the agent are co-located in the *same process* — tighter than
  even Kernel's "co-located deploy."

## Where they genuinely win (the honest gaps)
- **Real-browser fidelity.** They run actual Chromium: full JS, canvas/WebGL, service workers, complex
  SPAs, exact layout. We cover SSR + light JS well (empirically, most of the web), and have the
  StarlingMonkey+linkedom fallback for client-only shells — but we are **not** a pixel-exact full
  browser and won't be for the hard 10%.
- **Anti-bot is our zero.** Stealth, CAPTCHA solving, residential-proxy/IP rotation, TLS-fingerprint
  management — all three offer some; we offer **none**. This *is* the Wikipedia-class failure: not a
  render gap, an **identity/network** gap. Bot-protected sites will block our brokered fetch.
- **Observability/replay.** Kernel's live-view + MP4 replay + remote GUI is a real ops feature we don't have.

## Bottom line
On the **agent computer-use front** — semantic action model + vision loop + render/extract — we are
**comparable to Browser Use's brain** and deliver it at a **fraction of the compute with zero external
infra**, because we skipped the browser. We are **behind on the two things that need a real browser or
a real network identity**: heavy-SPA fidelity and anti-bot/stealth/proxy. For our actual use case
(SSR + light-JS sites, run concurrently from the runtime), we're already in good shape. The honest
roadmap to close the gap is **not** "build Chromium" — it's (1) the StarlingMonkey fallback for the
SPA tail (done, kept as a fallback for compute reasons), and (2) a **network-identity layer** (real UA,
TLS profile, optional proxy egress through the broker) to stop being trivially fingerprinted — which is
higher leverage for real-world computer-use than any further rendering work.
