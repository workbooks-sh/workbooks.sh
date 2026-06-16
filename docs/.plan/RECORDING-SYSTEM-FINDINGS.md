# Recording System — Findings Report

*Automated demo/tutorial recording + UI/UX regression for the Workbooks Browser.*
*Synthesis of six research dimensions against `RECORDING-SYSTEM-BRIEF.md`. Date: 2026-06-13.*

---

## 0. The one-line answer

Build the **native Mac rig now** (it ships landing/blog/LMS/docs content within ~1 week of work),
and pursue the **Nexus toolkit as a host-brokered browser cap** — NOT browser-in-WASM. The two
tiers are not different systems: they share **one seam** — *the guest/driver emits intents
(`click`/`type`/`screenshot`/`eval_js`), a trusted host executes them and returns pixels/DOM.*
The native tier runs that seam against the real Tauri window over the **embedded MCP**; the Nexus
tier runs the identical intents through a `Workbooks.Browse` broker provider. Render + native
engine = always host. Intent + verification logic = can live in-guest.

And one corrected premise from the brief: **DeepSeek V4 is not a pixel-grounded computer-use
driver**, and **the primary driver should be deterministic MCP scripts, not any frontier model.**
Models are the *fallback* and the *verifier*, not the steering wheel.

---

## 1. Two-tier architecture

### Tier 1 — Native Mac rig (BUILD NOW)

```
                ┌─────────────────────────────────────────────┐
   Claude Code  │  record.sh start|stop|shot  (3-verb shim)    │
  (background    │   └─ PID file /tmp/wb-rec.json               │
   orchestrator) └─────────────────────────────────────────────┘
        │                    │                       │
        │ drive              │ capture               │ verify
        ▼                    ▼                       ▼
  Embedded MCP          ScreenCaptureKit        Gemini 3 Flash → 3.1 Pro
  (work desktop mcp)      → VideoToolbox H.264     (video proof gate)
  click/type/eval_js    → ffmpeg stills          MiniMax M3 tiebreak
        │                + gifski GIF
        ▼
  Real Tauri window (WKWebView), seeded demo env (work demo seed)
```

- **Capture:** ScreenCaptureKit (window-scoped, GPU zero-copy) → VideoToolbox H.264 MP4 + ffmpeg
  stills + gifski GIFs.
- **Drive:** the **embedded MCP** (`work desktop mcp --stdio`) for the real app; **Playwright +
  ghost-cursor + Stagehand** when the artifact is a polished *web* walkthrough (dev frontend or
  arbitrary web), where animated cursor/typing matters and Chromium is fair game.
- **AI:** drive ~$0 (deterministic MCP scripts); fallback to **Claude Opus 4.8 computer-use** for
  unscripted pixel steps. Verify with **Gemini 3 Flash → 3.1 Pro → MiniMax M3** cascade.
- **Proof loop:** record → vision gate → pass publishes, fail returns the failing step+timestamp,
  Claude re-drives and re-records, bounded by wall-clock `TIMEOUT_MS` (no turn cap, per canon).

### Tier 2 — Nexus toolkit (RESEARCH PATH, partially built)

Same intents, different endpoint. Tenant code in WASM (bash-only agent) calls `3w browse`; the
host `Workbooks.Browse` provider executes CDP against a host-owned browser and returns
screenshots/DOM. The renderer and encoder *always* live host-side. This is **BEDROCK-resolved-by-
broker**, the same pattern as HTTP/exec/net. Feasible now as a capability; the blocker is wiring,
not research.

**The line:** rendering + native engine = host, forever. Intent emission + verification = guest-eligible.

---

## 2. Tool + model picks per dimension

### Dimension 1 — macOS capture
- **Pick: ScreenCaptureKit (SCK) source + VideoToolbox encode.** NOT ffmpeg/avfoundation — that
  uses the deprecated CGWindowList path, can't cleanly capture a single window, and lags the cursor.
- **Implementation:** start with **SwiftCapture (`scap`)** (SCK-based, maintained, real CLI:
  `scap --app Workbooks --fps 60 --quality high`). Caveat: MOV-only, no stills → transcode
  downstream. Migrate to a **~150-line in-repo Swift `SCStream` shim** for the long-lived rig
  (gives stills via `SCScreenshotManager`, window-id targeting, removes third-party risk).
- **Encode:** `h264_videotoolbox -q:v 55–70 -pix_fmt yuv420p` (Apple-Silicon constant-quality).
  H.264 for web compat; HEVC only if size matters. **60fps** for typing/cursor, 30fps for static docs.
- **Stills:** `ffmpeg -ss <t> -i in.mov -frames:v 1 still.png` (or SCScreenshotManager direct).
- **GIFs:** `ffmpeg ... fps=15,scale=...:lanczos | gifski` — gifski beats palette-ffmpeg on UI text.
- **Hard caveat:** SCK needs **TCC Screen Recording permission** granted to the *parent process*
  (Terminal/Claude Code host). One-time manual grant, cannot be scripted. No offscreen mode →
  needs a logged-in GUI session (this is why CI runs are a pre-release gate, not per-push).

### Dimension 2 — driving the UI
- **Decisive constraint:** the Workbooks Browser is Tauri/wry → **WKWebView on macOS, not
  Chromium** (confirmed: `objc2-web-kit` in `desktop/src-tauri`). **Playwright/Puppeteer/Stagehand
  cannot attach to it** — they drive a browser they launch.
- **Pick: two-driver split.**
  - **(A) Real app → embedded MCP (`wb-aakl.11/.23`).** Only seam that controls the shipped app.
    Exposes `click`/`type`/`hover`/`screenshot`/`dom_read`/`eval_js` + native tools
    (`tabs_*`/`open_workbook`/`weave`/`viewer_state`) over UDS, 1:1 onto 112 existing Tauri
    commands. **Caveat: `.23` (the `eval_js`/`dom_read` JS-bridge + synthetic events) is unbuilt —
    the single highest-leverage blocker for app-tier recording AND testing.**
  - **(B) Web walkthroughs → Playwright headful Chromium** (records WebM natively). Add
    **ghost-cursor-play** (Bézier human paths) + a CSS cursor overlay via `addInitScript` so motion
    is *visible*; type with `pressSequentially` + Gaussian-jittered delays.
- **Scripted vs AI:** deterministic-first (recordings must replay byte-identical to be regression
  tests). Use **Stagehand v3** (stable Mar 2026, modular driver, caches AI selectors) as the
  *authoring/self-heal aid*, not the runtime path. Commit cached selectors.
- **Terminal tutorials:** **asciinema** record → **svg-term-cli** for web (crisp, tiny, selectable);
  **agg→GIF→ffmpeg→MP4** only when compositing terminal into screen video.

### Dimension 3 / 3b — AI drive + verify + proof loop

| Role | Model | id | $/M (in/out) | Note |
|---|---|---|---|---|
| Primary driver | *none — MCP scripts* | `work desktop mcp` | $0 | deterministic, reproducible |
| Driver fallback (pixels) | **Claude Opus 4.8** | `claude-opus-4-8` | 5 / 25 | 83.4% OSWorld, the real CU leader; use sparingly |
| Driver fallback (MCP, cheap) | DeepSeek V4 Flash | `deepseek-v4-flash` | 0.14 / 0.28 | tool-calls only, **NOT pixels** |
| Verify — triage | **Gemini 3 Flash** | `gemini-3-flash` | 0.50 / 3.00 | 1fps sample, finds error frames+timestamps |
| Verify — deep gate | **Gemini 3.1 Pro** | `gemini-3.1-pro` | 2 / 12 | re-checks flagged spans at high res |
| Verify — tiebreaker | MiniMax M3 | `minimax-m3` | 0.60 / 2.40 | native video, cross-vendor |

- **Brief correction:** DeepSeek V4 (released 2026-04-24) is a strong agentic *tool-caller* (80.6%
  SWE-bench) but has **no native GUI grounding** (no first-party screenshot→coordinate action). Use
  it as a budget MCP orchestrator only. The actual computer-use leader is **Opus 4.8**.
- **Why Gemini for verify:** 1M context = up to 1hr video default / 3hr low-res, with
  `media_resolution` control. The Flash→Pro multi-stage is Google's own documented long-video recipe.
- **Proof loop:** record → Gemini 3 Flash ("did each step's expected UI appear? list error/red-
  text/crash frames+timestamps") → clean publishes; flagged → Gemini 3.1 Pro re-checks span at high
  res → disagreement → MiniMax M3 breaks tie. Only Flash-clean or 2-of-3 PASS publishes.
- **Honest caveat:** sampling-based verify (default 1fps) can miss a one-frame error flash — pin
  critical assertions to specific timestamps and bump fps/resolution for those spans. Pair every
  visual checkpoint with a cheap DOM/text assertion so a green pixel-diff isn't the only signal.

### Dimension 6 — testing reuse (one harness, two products)
- **The recording harness IS the regression suite.** A demo flow and a "still works + looks right"
  test are the *same trajectory*. Author one named flow = `[{action, checkpoint}]`; run it in
  **publish mode** (cursor anim + capture → MP4/GIF) or **assert mode** (golden-screenshot + DOM-
  snapshot diff). Same script, selectors, seeded env.
- **`tauri-driver`/WebDriver is a dead end on macOS WKWebView** (Apple ships no WebDriver for
  embedded WKWebView; tauri-driver is Win/Linux only; community plugins experimental). **Drive
  tests through the MCP**, reusing the same 112 Tauri commands — grants no new capability.
- **Diff engine:** `pixelmatch` (what Playwright's `toHaveScreenshot` wraps). Tier A (now): thin
  Bun harness — MCP `screenshot` PNG → pixelmatch (threshold/maxDiffPixels) → `*-actual/*-diff.png`,
  baselines in existing `desktop/.shots/`. Tier B (later): Argos CI for hosted review UI.
- **Discipline:** generate baselines on ONE canonical Mac (font rendering differs); pin OS/scale/
  window size via MCP resize; mask volatile regions (timestamps, token counts); add DOM-snapshot
  diffing (`dom_read` normalized outerHTML) for structural regressions invisible to pixels.
- **Critical-path dependency: same `eval_js`/`dom_read` JS-bridge (wb-aakl.23).**

---

## 3. Demo-environment spec (reproducible seed)

**Seed as a git-backed Org tree, NOT a database.** Everything the Browser shows already resolves
from `workspace.org`/`:toolkit:`/`:agent:` Org files in a per-tenant repo
(`Workbooks.Git.repo_path(tenant) = $WB_DATA/<tenant>`). A reproducible demo = **a versioned
fixture repo + a deterministic loader** (the "seed-file" pattern: most repeatable, version-
controlled, dependency-free).

**Shape — all already-supported primitives, no new host code paths:**
- **Multiple workspaces** — three `workspace.org` manifests: `acme-growth` (marketing/data),
  `northwind-ops` (workflows/agents), `studio` (toolkit-authoring). Members reference real files by
  `:PATH:`/`:DID:` with `:SCOPE: read|write`.
- **Multiple team members** — `WB_TENANCY_MODE=multi`; seed 3–4 tenants (`ada`/`grace`/`alan`/
  `demo-bot`), each a **deterministic `WB_SIGNING_KEY` seed** so DIDs are stable across re-
  materialization (extend the existing fixed-32-byte-seed keypair logic per-tenant). Cross-tenant
  `:SCOPE:` shares show the Library access graph.
- **Real workbooks + folders** — single-file `.html` plus Org workbooks that actually tangle+build+
  run via existing `Demos.Build` lanes (JS/Rust/Go/C/polyglot). **Don't fake outputs — run at seed
  time** so the Browser shows real run records.
- **Custom toolkits** — 1–2 demo toolkits as `:toolkit:` Org nodes under `$WB_TOOLKITS_ROOT`
  (point at `runtime/demos/seed/toolkits`), each with skills + a signed manifest
  (`Workbooks.Toolkits.sign_text/3`) so `work toolkit list/verify` is green on camera. Reuse the
  `huniq` autobuild shape.
- **Set-up agents** — `:agent:` Org nodes with mandatory `** System prompt`, `:MODEL:`,
  `:TOOLKITS:`. Pin `MODEL: xiaomi/mimo-v2.5`; for recordings prefer **replayed transcripts**.
- **Custom Dock** — ship `demo-dock.json` chrome/membrane preset (pinned tiles + routing) loaded
  via a `WB_DEMO=1` env gate the desktop reads at boot
  (`desktop/src/lib/bridge/dock.svelte.ts`).

**Determinism levers (the no-flaky requirement):**
1. **Freeze the clock** — inject "now" behind the `Pipeline` `SCHEDULED:` timestamps.
2. **Replay agents** — record one good transcript per demo; `WB_DEMO_REPLAY=1` serves it instead of
   OpenRouter (kills LLM nondeterminism + cost from every take).
3. **Stable IDs** — replace `System.unique_integer`/`Tenant.ephemeral` in the demo path with seeded
   ids so DIDs/run-ids/filenames don't churn.

**Plug-in:** a `work demo seed --fresh --tenancy multi` escript verb wraps a new
`Workbooks.Demos.Seed.materialize/1` (peer to `Demos.Build`) → clean `$WB_DATA`+`$WB_TOOLKITS_ROOT`
+dock preset → boots `WB_WEB=1` runtime + Tauri app with `WB_DEMO=1`. The harness shells this before
every take; the check-model asserts seeded state rendered (tiles present, runs green) before publish.

**Ready today:** Org workspaces/agents/toolkits, git seeding, build/workflow demos, toolkit signing.
**Small build (~1–2 days):** `Demos.Seed.materialize/1`, per-tenant key seeds, `WB_DEMO`/replay/
clock gates, `demo-dock.json`+loader, `work demo seed`. **Riskiest knob:** multi-tenancy (mint short-
lived demo JWTs at seed time; never seed into the shared `"default"` partition — it fails-isolated).

---

## 4. In-WASM / Nexus feasibility verdict

**Question: can browser-level computer-use run inside WASM/BEAM with no native exec?**

### Verdict by option, classified against the three walls

| Option | Verdict | Wall |
|---|---|---|
| **Host-brokered browser cap** (guest emits intents, host drives real browser via CDP) | **FEASIBLE NOW** | BEDROCK-resolved-by-broker (not a wall) |
| **LightPanda-in-WASM** (compile the engine into the guest) | **HARD WALL** | BEDROCK + no renderer |
| **CDP-over-broker** | **= the browser cap** | same seam, reuse the MCP |
| **jitless JS interpreter in guest (SpiderMonkey-jitless)** | aspirational, wrong shape | FORGE; still no renderer |

**Why LightPanda-in-WASM is a wall (and stays one):** LightPanda's JS runtime is **prebuilt V8** —
a JIT that emits native code at runtime. That is textbook BEDROCK (no native, no JIT, W^X). You
cannot compile LightPanda+V8 to wasm32-wasi and run it sealed. LightPanda's own "embeddable C lib /
WASM module" is **roadmap, not shipped** (confirmed June 2026 — beta browser only). Even if it
ships, a wasm LightPanda needs a jitless JS interpreter AND **has no renderer** (no layout/raster) —
so it cannot produce the *visual* recordings the brief wants. Dead end for our use case.

**The correct shape (fits canon exactly):** the guest never browses. It emits intents across the
Dock membrane to a **trusted host service** owning a real browser via CDP — same broker pattern as
HTTP/exec/net. The tenant gets computer-use *semantics* with zero native exec. **Reuse existing
assets:** `runtime/host/browse.ex` is the pluggable provider dispatcher; the `3w` toolkit already
invokes `lightpanda fetch` host-side. The browser cap is a **new `Browse` provider/EXEC-shape, not
new host primitives.** LightPanda stays useful *host-side* for cheap headless DOM reads — never
compiled into the guest.

**Maturity honesty:** the broker cap is *architecturally proven, partially built* — the MCP server
is `wb-aakl.23` (⏳; the JS-bridge round-trip is the hard 20%). No research risk; it's wiring.
Computer-use reliability is still ~70–85% on long loops — *that is why* the Gemini-video proof gate
+ retry is mandatory, not optional.

---

## 5. Phased build plan

**Phase 0 — JS bridge keystone (UNBLOCKS EVERYTHING).** Land **wb-aakl.23**: the Rust UDS server,
stdio relay, and `eval_js`/`dom_read` JS-bridge round-trip + synthetic-event injection. This is the
single dependency shared by app-tier recording (D2), testing reuse (D6), and the Nexus path (D5).
*Until this lands, app recording falls back to Opus computer-use or web-only Playwright.*

**Phase 1 — Native capture rig.** `record.sh start|stop|shot` (SwiftCapture + PID file +
VideoToolbox transcode + ffmpeg stills + gifski). Grant TCC permission once. Output: real MP4s of
the app today, even before the MCP bridge (drive manually/Opus while .23 lands).

**Phase 2 — Demo seed.** `work demo seed` + `Demos.Seed.materialize/1` + deterministic key/clock/
replay gates + `demo-dock.json`. Now every take runs against identical rich state.

**Phase 3 — Proof loop.** Wire Gemini 3 Flash → 3.1 Pro → MiniMax M3 cascade behind a
`check_recording` step Claude calls; record→verify→retry under `TIMEOUT_MS`.
**→ At end of Phase 3 we can record landing/blog/LMS/docs content reliably.**

**Phase 4 — Web walkthrough lane.** Playwright + ghost-cursor-play + Stagehand v3 + asciinema/svg-
term for the polished-web and CLI-tutorial artifacts.

**Phase 5 — Testing reuse.** Promote flows to assert-mode: pixelmatch + DOM-snapshot diff against
`desktop/.shots/` baselines; pre-release CI job on the tagged `desktop-v*` build (not per-push —
macOS GUI CI is slow/flaky).

**Phase 6 — Nexus toolkit.** Add the `Workbooks.Browse` CDP-over-broker provider so tenant bash
agents (`3w browse`) get host-brokered computer-use. Same intents as Phase 0, second endpoint.

---

## 6. Open questions

1. **wb-aakl.23 effort/owner** — the JS-bridge round-trip is the gating 20%. Is it scoped/staffed?
   Everything downstream waits on it.
2. **Cursor/typing realism for the *real app*** — MCP synthetic events are invisible (no animated
   cursor). Do we (a) draw a host-side overlay cursor during native capture, (b) accept no visible
   cursor for app demos, or (c) reserve "pretty cursor" demos for the Playwright web lane only?
3. **TCC permission in any unattended/CI context** — one-time manual grant + logged-in GUI session
   required. Acceptable for the solo Mac box; what's the story if recording ever moves to a runner?
4. **Replay vs live agents on camera** — replayed transcripts give determinism but are "fake runs."
   For marketing authenticity, do we want at least the hero demo to be a live (seeded, pinned-model)
   run, accepting the nondeterminism?
5. **Verify-gate cost ceiling** — Flash triage is pennies, but Opus computer-use fallback + Pro
   deep-checks add up on long/retried recordings. Set a per-recording $ budget that aborts to a
   human-review queue?
6. **Vendor-route risk for the publish gate** — DeepSeek/MiniMax are open-weight via third-party
   hosts (weaker SLAs). Keep them strictly as cheap/tiebreaker tier; is Gemini (+Anthropic) alone
   sufficient as the gate of record?
7. **Baseline drift on macOS upgrades** — golden screenshots break on OS font-rendering changes.
   Re-baseline cadence + who approves?

---

## 7. Empirical run — 2026-06-14 (web tier, desktop-app demos + voiceover)

Goal: produce real, vision-verified, *voiced* demo videos of the Workbooks
Browser desktop UI, and validate the toolkit on this macOS box.

### What was produced (all verified PASS, all voiced, all live on R2)

The desktop app was driven as a **web app** (`cd desktop && bun run dev`, vite
:5178, `$lib/platform/webHost` mock providers) — the legitimate cross-platform
desktop-UI demo lane. Four `target:"web"` recipes, each `./pipeline …
--voiceover recipe` → recorded WebM → MP4 → ElevenLabs narration muxed in →
re-verified the FINAL voiced MP4 with the vision cascade.

| Demo | Recipe | Final-MP4 verify | R2 URL |
|---|---|---|---|
| Command palette / shell | `recipes/desktop-command-palette.json` | pass 0.90 | `…/demos/desktop-command-palette.mp4` |
| Search drawer | `recipes/desktop-search-drawer.json` | pass 1.00 | `…/demos/desktop-search-drawer.mp4` |
| Kanban workbook | `recipes/desktop-kanban-workbook.json` | pass 1.00 | `…/demos/desktop-kanban-board.mp4` |
| Tabbed workspaces | `recipes/desktop-tabs-navigation.json` | pass 1.00 | `…/demos/desktop-tabbed-workspaces.mp4` |

R2 base: `https://pub-eecb84bd77df49bebf6ffbd196a7c627.r2.dev`
(bucket `workbooks-media`, prefix `demos/`; all 4 return `200 video/mp4`).
Verify cascade: `google/gemini-3.5-flash` (triage) via OpenRouter, on the muxed
voiced MP4 (not just the silent WebM). Videos are NOT committed (R2 is canon).

### Toolkit bugs found + fixed this session

1. **`hover` ignored `x,y` coordinates** (`lib/backend-playwright.mjs`). `click`
   accepted `{selector | x,y}` but `hover` only handled `selector`, so a
   coordinate hover threw. Fixed to mirror `click` (DRY). This mattered because
   **each workbook renders inside an iframe** — main-frame text selectors
   (`text=…`, `getByText`) can't see card content, so coordinate hover is the
   reliable intent for inside-workbook interaction. Documented gotcha.
2. **No voiceover stage existed** (task gap, not a bug). Added
   `lib/voiceover.mjs` (ElevenLabs v3, reuses the `web/learn/audio/generate.mjs`
   call pattern + `XI_API_KEY`): TTS per line → `adelay`/`amix`/`apad` evenly
   paces clips across the video's real `ffprobe` duration → muxes AAC over the
   copied video stream. Wired `--voiceover <script.json|recipe>` (+
   `WB_REC_VOICEOVER`) into `pipeline`; the web branch now finalizes WebM→MP4
   and records `finalVideo`/`voiced` in the manifest. A `voiceover` block on the
   recipe (`{"lines":[…]}`) is the zero-arg path.

### Honest gaps / not-validated

- **Native Tauri app tier (`target:"app"`)**: confirmed wiring-gated, exactly
  per §6 above. The pipeline does an honest macOS dry-validation and emits a
  non-publishable manifest. Did not sink time driving the native binary.
- **Some sidebar workspaces are stubs** in the mock webHost (Notes, Tracker,
  Reading render a "This is a placeholder page. No real workbook is wired"
  card). Only **Kanban** is a fully-rendered workbook today, so it's the one
  "real workbook" demo. Demos picked around this (shell/search/tabs +
  the one real Kanban board) so every frame is clean and non-empty.

### Nexus-in-WASM verdict (RUNBOOK §8) — **BLOCKED / unbuilt, evidence below**

Read `runtime/host/browse.ex` + `runtime/host/browse/provider.ex` +
`runtime/host/browse/native.ex`:
- `Workbooks.Browse.Provider` declares **exactly** `@callback capabilities()
  :: [:fetch | :crawl | :search]` — there is **no `:drive` capability**.
- `Native.capabilities/0` returns `[:fetch, :crawl, :search]`; `Browse`'s only
  public verbs are `fetch/2`, `crawl/2`, `search/2`. No `navigate/click/type/
  screenshot/eval_js` anywhere in `runtime/host/`.
- `grep -rn ':drive\|Browse.Drive'` over `runtime/host/` → **0 hits.** The only
  MCP reference is `cli/desktop.ex` (`work desktop mcp --stdio`), a stdio↔UDS
  **relay for Claude Code → the live browser**, whose own comment says the
  in-browser MCP **server** is "impl wb-aakl.23" — i.e. not shipped.

So a bash-only WASM guest emitting a record intent across the Dock and getting
back pixels/DOM **cannot round-trip today**: no `:drive` provider, no guest
EXEC-shape, and no shipped MCP server to receive the intents. I did **not** wire
a fake round-trip. The remaining wiring is precisely:
1. add `:drive` to the `Browse.Provider` behaviour + a `Workbooks.Browse.Drive`
   provider whose executor shells this `tools/record` rig (it already speaks the
   locked intent set);
2. ship the in-browser MCP **server** (`wb-aakl.23`) so intents actually execute;
3. expose `:drive` as a toolkit EXEC-shape over RCP so a wasm tenant emits
   intents across the Dock membrane.
Maturity: architecturally proven, **unbuilt** (not merely "partially built" —
the capability slot itself does not yet exist). The vision-verify gate
(`lib/verify.mjs`) and demo seed are host-side and would gate any take
regardless of emitter — those are done.
