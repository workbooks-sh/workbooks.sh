# Research Brief — Automated Demo / Tutorial Recording & UI-UX Testing System

## The goal
A system, **drivable by Claude Code in the background**, that produces real, fully-fleshed
demo content — screen recordings, screenshots, click/cursor/typing animations, terminal
tutorials — of the **Workbooks Browser** (the desktop app) and Workbooks generally, for use
in: a new **landing-page "the Browser" section below the hero**, the **blog**, the **LMS**,
and the **docs**. The same system doubles as **UI/UX regression testing** for the app.

The north star: this is eventually a **Nexus toolkit** — browser-level *computer use* running
**inside WebAssembly/BEAM (no native code outside WASM)** — so tenants and agents can record
and test their own workbooks/UIs from inside the sandbox. We expect a **two-tier answer**: a
pragmatic *native Mac rig we can use today* (for marketing content now), and a *research path*
to the in-sandbox toolkit. The brief must find both and name the line between them.

## Hard constraints / canon
- **BEDROCK wall:** no native execution in the guest; the only escape is a trusted host-service
  broker (see runtime/.campaign/WALLS.md, memory three-walls-canon). The Nexus-toolkit version
  must be WASM + host-brokered caps — NOT Playwright/Chromium native in the guest.
- We have **LightPanda** (a lightweight headless browser) and wasmtime + the BEAM. The Workbooks
  Browser is a **Tauri** desktop app (desktop/) with a Host capability seam + an embedded MCP
  (wb-aakl.11) that can drive it.
- Mac dev box → bare-metal GPU available for the native tier.

## Dimensions to research (each → concrete recommendation)
1. **LINUX capture (NOT macOS — corrected):** Workbooks runs almost entirely in the **Linux
   kernel** — the krunvm container locally and Linux in the cloud — so capture must target
   Linux, not the Mac host. Record the app's **Linux build** (Tauri = WebKitGTK) and the runtime
   inside a headless Linux display: **Xvfb/Xephyr + ffmpeg `x11grab`** (or `kmsgrab`/GPU), or
   **wayland + wf-recorder**, runnable both in the local container and in cloud Linux. MP4 +
   stills/GIFs. This is more portable, cloud-runnable, and collapses toward the Nexus/WASM path
   (same Linux substrate). The Mac host is just where we trigger it, not where capture happens.
2. **Driving the UI (native tier):** Playwright vs Puppeteer vs **Stagehand** vs the Workbooks
   Browser's **embedded MCP**; animated cursor + realistic typing; deterministic scripted runs
   vs AI-driven. Terminal tutorials (asciinema/agg → video) for CLI flows.
3. **AI computer-use & verification:** which model **drives** vs **checks**. Candidates the user
   named: **DeepSeek V4** (strong computer-use → drive the tutorial), **Gemini latest w/ video**
   and **MiniMax M3** (→ watch the recording and answer "did it work, any errors?"). Recommend a
   drive-model + a check-model + the proof loop (re-run on failure).
3b. **The proof loop:** how Claude Code, in the background, decides a recording is GOOD
   (no errors, the feature actually worked) before publishing — vision-model gate + retries.
4. **The demo environment (no corners cut):** a reproducible, fully-seeded Workbooks demo
   workspace — real workbooks, folders, **custom toolkits**, a **custom Dock**, agents actually
   set up, **multiple workspaces, multiple team members**, realistic data. How to define + seed
   it as code so any recording runs against the same rich state. This is its own spec.
5. **The Nexus-toolkit path (the keystone research):** can browser-level computer-use run
   **inside WASM/BEAM** with NO native exec? Options: LightPanda compiled/embedded, a
   host-brokered "browser cap" (the engine drives a real browser, the guest only issues
   intents), CDP-over-broker, or a wall we must document. Map feasible vs aspirational vs wall.
6. **Reuse for testing:** how the same harness becomes UI/UX regression tests for the Workbooks
   Browser and for arbitrary workbooks.

## Deliverable
A findings report (`docs/.plan/RECORDING-SYSTEM-FINDINGS.md`) with: the recommended **two-tier
architecture**, the exact tool/model picks per dimension with rationale, the **demo-environment
spec**, the **in-WASM/Nexus feasibility verdict** (with the line clearly drawn), a **phased
build plan**, and open questions. Honest about what ships today vs what's a research wall.
