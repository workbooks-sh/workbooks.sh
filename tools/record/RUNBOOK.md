# Recording System — RUNBOOK

The operator's guide to `work record` — the single, Claude-Code-runnable pipeline
that produces verified demo/tutorial content (MP4 + stills + GIF) of the
**Workbooks Browser** and Workbooks generally, for the landing page, blog, LMS,
and docs. The same harness doubles as UI/UX regression testing.

Architecture + rationale: `docs/.plan/RECORDING-SYSTEM-FINDINGS.md`.
Canon: **no native exec in the guest**; capture is a **host-side trusted service**
on **Linux** (the substrate the app + runtime run in — krunvm locally, cloud
Linux); the Mac host only **triggers**. (`CLAUDE.md`, `runtime/.campaign/WALLS.md`.)

---

## 0. TL;DR — one command

```sh
# Inside the Linux substrate (krunvm container / cloud Linux):
tools/record/pipeline tools/record/recipes/app-demo.example.json

# From the Mac host (it shells into the Linux substrate for you):
tools/record/trigger-from-mac.sh pipeline tools/record/recipes/app-demo.example.json
```

That one command runs the whole proof loop:

```
seed demo env → display-up + launch app → START capture (MP4)
   → DRIVE the recipe intents (record.mjs) → STOP capture (finalize MP4)
   → make GIF → VERIFY the real MP4 (Gemini→MiniMax cascade)
   → PASS publishes / FAIL retries, bounded by TIMEOUT_MS
```

Output: `<out>/pipeline.json` (publishable flag, verdict, artifact paths) +
`<out>/<take>.mp4`, `<take>.gif`, `*.png` stills. Exit 0 = publishable, 1 = not.

---

## 1. The pieces (and how `pipeline` joins them)

| File | Role |
|---|---|
| `tools/record/pipeline` | **THE orchestrator.** Coordinates seed → capture-around-drive → verify → retry. The wiring the Foundations phase was missing. |
| `tools/record/record` | Linux capture rig (Xvfb/x11grab/kmsgrab/wayland → MP4; stills; GIF). `record pipeline …` aliases the orchestrator. |
| `tools/record/record.mjs` | Driver + (inline) verify for the **web** tier. The orchestrator calls it `--no-verify --emit-context` for the **app** tier so it just drives + drops `<take>.expected.txt`/`.signals.json`. |
| `tools/record/lib/backend-mcp.mjs` | App-tier driver: intents → the Browser's embedded MCP (`/tmp/workbooks-mcp.sock`). |
| `tools/record/lib/backend-playwright.mjs` | Web-tier driver: Chromium + visible cursor + human typing, self-records WebM. |
| `tools/record/lib/voiceover.mjs` | Adds a narrated track to a recorded MP4 (ElevenLabs v3; `XI_API_KEY`). TTS per line → paced across the video's real duration → muxed AAC. CLI: `node lib/voiceover.mjs --video f.mp4 --script narration.json`. Wired into `pipeline` via `--voiceover <script.json|recipe>` / `WB_REC_VOICEOVER`; a recipe `"voiceover":{"lines":[…]}` block is the zero-arg path. |
| `tools/record/lib/verify.mjs` | The proof cascade (Gemini 3.5 Flash → 3.1 Pro → MiniMax M3). |
| `tools/record/lib/verify-only.mjs` | Run that cascade against an **already-captured** MP4 (the orchestrator gates the *real* capture, not a still-strip). |
| `runtime/demos/seed/` + `work demo seed` | The reproducible demo environment every take plays against. |
| `tools/record/trigger-from-mac.sh` | Mac → Linux trigger (krunvm/podman/docker/ssh seam). |

**Two targets, one seam.** A recipe's `"target"` decides the lane:
- `"target":"app"` → coordinated Linux capture of the real Tauri app via MCP.
- `"target":"web"` → `record.mjs` + Playwright records its own WebM (no Linux
  display/app/capture-rig needed); the orchestrator just delegates + verifies.

---

## 2. Recipes

A recipe is JSON: a `name`, a `target`, and `steps[]` of driver-agnostic intents
(`navigate`/`click`/`type`/`hover`/`wait`/`screenshot`/`eval_js`/`dom_read`).
Any step with `"checkpoint"` grabs a still the verifier anchors on.

Starters:
- `tools/record/recipes/app-demo.example.json` (app/MCP)
- `tools/record/recipes/web-walkthrough.example.json` (web/Playwright)

Intent contract: `tools/record/lib/intents.mjs`.

---

## 3. Local run (Mac dev box → krunvm Linux)

### 3a. One-time, inside the Linux substrate
```sh
tools/record/lib/deps.sh check      # Xvfb + ffmpeg required; xdotool/gifski/etc optional
tools/record/lib/deps.sh install    # apt/apk/dnf (needs root in the container)
tools/record/record selftest        # synthetic Xvfb capture → proves the rig
```

### 3b. Provide the app + MCP socket
The orchestrator needs the **Workbooks Browser Linux build** on the virtual
display with its embedded MCP listening:
```sh
# launch the app yourself, OR let the pipeline launch it:
tools/record/pipeline <recipe> --app "/opt/workbooks/workbooks-browser --mcp"
```
The app must start its MCP server (`WB_MCP=1`) so `/tmp/workbooks-mcp.sock`
(override `WB_MCP_SOCK`) is live. The driver auto-detects the socket.

### 3c. Run it
```sh
tools/record/pipeline tools/record/recipes/app-demo.example.json \
  --app "/opt/workbooks/workbooks-browser --mcp" \
  --retries 2 --timeout-ms 900000
```

### 3d. From the Mac host (don't enter the container manually)
```sh
WB_REC_BACKEND=krunvm WB_REC_CONTAINER=workbooks \
  tools/record/trigger-from-mac.sh pipeline tools/record/recipes/app-demo.example.json
```
Backend seam: `WB_REC_BACKEND=krunvm|podman|docker|ssh`, `WB_REC_CONTAINER=<id>`,
`WB_REC_SSH=user@host`, `WB_REC_REPO=/workspace/workbooks` (repo path in guest).

---

## 4. Cloud run (cloud Linux)

Same `pipeline`, different trigger. The cloud box already **is** Linux, so run
`pipeline` directly there, or trigger over ssh:
```sh
WB_REC_BACKEND=ssh WB_REC_SSH=ops@runner.example \
  WB_REC_REPO=/srv/workbooks \
  tools/record/trigger-from-mac.sh pipeline recipes/app-demo.example.json
```
Cloud notes:
- Headless by design (Xvfb). No GUI session, no TCC — unlike a native-macOS rig,
  this Linux path is fully unattended-capable (a key reason capture is Linux).
- GPU `kmsgrab`/VAAPI is auto-preferred when a DRM device is present, else
  `x11grab` (`record start` picks). Set `WB_REC_FPS`/`WB_REC_CRF` for quality.
- Pull artifacts from `<out>/` (default `tools/record/out/<slug>/`).

---

## 5. Env / keys

| Var | What | Default |
|---|---|---|
| `OPENROUTER_API_KEY` | the verify cascade (Gemini/MiniMax over OpenRouter). Also read from `~/.workbooks/groundskeeper.env` / `wb-site.env`. **No key → verify SKIPS (publishes, honestly flagged) — not a hard fail.** | — |
| `WB_VERIFY_TRIAGE` / `_DEEP` / `_TIEBREAK` | override the cascade models | `google/gemini-3.5-flash` / `google/gemini-3.1-pro-preview` / `minimax/minimax-m3` |
| `WB_MCP_SOCK` | the Browser's MCP UDS | `/tmp/workbooks-mcp.sock` |
| `WB_REC_DRIVER` | `mcp` / `playwright` / `auto` | `auto` |
| `WB_REC_RETRIES` / `WB_REC_TIMEOUT_MS` | re-takes / wall-clock budget (no turn cap, per canon) | `1` / `900000` |
| `WB_REC_SEED_ARGS` | args for `work demo seed` | `--no-build` |
| `WB_REC_APP` | app launch cmd (alt to `--app`) | — |
| `WB_REC_DISPLAY/_W/_H/_FPS/_CRF/_CURSOR` | capture knobs (`lib/common.sh`) | `:99` / `1440` / `900` / `30` / `20` / `1` |
| seed gates | `WB_TENANCY_MODE=multi`, `WB_DEMO=1`, `WB_DEMO_REPLAY=1`, `WB_DEMO_NOW`, `WB_DATA`, `WB_TOOLKITS_ROOT` (exported by `work demo seed`) | — |

---

## 6. Honest state — what runs TODAY vs what's env-gated

**Runs today (verified on this host):**
- The orchestrator wiring: arg parsing, recipe introspection, seed step,
  target-routing (app vs web), capture lifecycle calls, retry loop, manifest
  emission, correct exit codes. Verified by running `pipeline` against both
  example recipes on macOS.
- `record.mjs` loads + drives **without Playwright installed** (lazy import) —
  so the app/MCP tier works in a minimal Linux container.
- The Linux capture rig (`record selftest`) produces a real synthetic MP4/PNG/GIF
  where Xvfb+ffmpeg exist (per the capture-rig phase).
- `work demo seed --dry-run` (stable DIDs, no writes) and the seed module.
- The verify cascade + `verify-only` load and call OpenRouter when a key is set.

**Env-gated (needs the real substrate / inputs — flagged honestly, not faked):**
- **A full publishable app take** needs all of: Linux display (Xvfb), the
  Workbooks Browser **Linux build** running on it, and its **MCP socket live**.
  On macOS the pipeline does an honest **dry validation** (loads driver, probes
  the socket) and emits a non-publishable manifest — it never fabricates a video.
- **The MCP JS-bridge (`wb-aakl.23`: `eval_js`/`dom_read`/synthetic click+type)**
  is the keystone. The js-bridge phase implemented the Rust UDS MCP server +
  bridge; until it is shipped in the Browser Linux build, app-tier `click/type/
  eval_js` round-trips won't drive. The backend is wired to the locked protocol
  and works unchanged when `.23` ships. *Until then: web-tier (Playwright) demos
  are fully functional today; app-tier is wiring-complete, ship-gated.*
- **The verify gate** needs `OPENROUTER_API_KEY`. Absent it, takes publish with
  `verdict:"skip"` recorded in the manifest (operator's call).
- **Web tier** needs Chromium (`playwright install chromium`, run from
  `tools/record/`).

Nothing here is committed — left for review per the task.

---

## 7. UI/UX regression reuse

The recording harness **is** the regression suite (findings §6). The same recipe
run in assert-mode = golden-screenshot (`pixelmatch`) + DOM-snapshot diff against
`desktop/.shots/` baselines, driven through the same MCP intents. The orchestrator
already drops `*.png` stills + `<take>.signals.json` (DOM) per take; the assert
lane is the small remaining add (compare-to-baseline instead of vision-verify),
gated on the same `wb-aakl.23` bridge. Run it pre-release on the tagged
`desktop-v*` build, not per-push (headless Linux GUI runs are the slow tier).

---

## 8. Next milestone — the in-WASM / Nexus toolkit

The whole pipeline is built on **one seam**: *the driver emits intents
(`click`/`type`/`screenshot`/`eval_js`); a trusted host executes them and returns
pixels/DOM.* Today the host is this Linux rig + the Browser MCP. The Nexus
milestone reuses the **identical intents** behind a host-brokered cap so tenant
**bash-only** agents in WASM can record/test their own UIs **with zero native
exec** — BEDROCK-resolved-by-broker, the same pattern as HTTP/exec/net.

**The exact path:**
1. `runtime/host/browse.ex` (`Workbooks.Browse`) is already the pluggable
   provider dispatcher (capabilities `:fetch`/`:crawl`/`:search`). Add a
   **`:drive` capability** + a `Workbooks.Browse.Drive` provider whose verbs are
   the intent set (`navigate/click/type/hover/screenshot/eval_js/dom_read`).
2. The provider's executor **is this rig** — it owns the display + encoder + the
   real browser (the renderer + native engine stay host-side **forever**; only
   intent-emission + verification logic are guest-eligible). Reuse the MCP
   transport: the provider speaks the same JSON-RPC the Browser MCP already does.
3. Expose it to the guest as a toolkit EXEC-shape (`3w browse drive …` / a
   `work record` shape over RCP) so a wasm tenant emits intents across the Dock
   membrane and gets back screenshots/DOM — never touching a display.
4. The proof loop (`verify.mjs`) and demo seed are unchanged: they already live
   host-side and gate any take regardless of who emitted the intents.

**Not on the path (documented walls, findings §4):** LightPanda-in-WASM /
V8-in-guest (BEDROCK: no JIT, and no renderer → no *visual* recording). Keep
LightPanda **host-side** for cheap headless DOM reads only.

**Maturity:** architecturally proven, partially built. The blocker is wiring
(`wb-aakl.23` bridge + the `:drive` provider), not research.
