# tools/record — the Linux capture rig

Records the Workbooks Browser (Tauri → **WebKitGTK on Linux**) or any X/Wayland
app **headlessly**, on Linux, producing MP4 + stills + GIFs, plus terminal-tutorial
videos. This is the **Tier-1 capture rig** from `docs/.plan/RECORDING-SYSTEM-FINDINGS.md`
— corrected to target **Linux, not macOS**: the app and runtime run in the Linux
kernel (krunvm container locally, cloud Linux). **The Mac host only triggers it.**

## Why Linux (not the Mac host)
Per canon (`CLAUDE.md`, `runtime/.campaign/WALLS.md`, memory three-walls-canon):
the app/runtime execute in the Linux substrate. Capturing on Linux is portable,
cloud-runnable, and collapses toward the Nexus/WASM path (same substrate). The rig
itself is a **host-side service** in the trusted Linux container — it is **never**
compiled into a wasm guest. The guest-facing seam is intent-only (a future
`Workbooks.Browse` provider brokers screenshot/click/type to this rig); the guest
never drives a display. No native exec in the guest is violated.

## Layout
```
tools/record/
  record                 main CLI (POSIX sh): display / capture / shot / gif / flow / selftest
  trigger-from-mac.sh    Mac-host trigger → shells into krunvm|podman|docker|ssh Linux
  flows/example-app.flow example record-flow script
  lib/common.sh          shared config + helpers (env knobs)
  lib/deps.sh            dependency check + install (apt/apk/dnf)
  lib/cursor.sh          animated cursor overlay (native pointer or sprite composite)
  lib/term.sh            terminal-tutorial capture (asciinema + agg → GIF/MP4)
```

## Dependencies (Linux)
Required (core x11grab → MP4): **Xvfb**, **ffmpeg**.
Optional (extends features): **xdotool** (drive pointer/keys + visible cursor),
**wmctrl**, **gifski** (better GIF text), **asciinema** + **agg** (terminal tutorials),
**xterm**/**xeyes** (selftest app), **Xephyr** (visible nested debugging),
**wf-recorder** (Wayland), **fonts-dejavu-core**.

Check / install (inside the Linux container):
```sh
tools/record/record deps              # report; nonzero exit if a required dep is missing
tools/record/lib/deps.sh install      # apt/apk/dnf install (needs root in container)
```
`gifski` and `agg` are Rust crates — `deps.sh install` best-effort `cargo install`s them;
GIFs fall back to ffmpeg palettegen if `gifski` is absent (acceptable).

## Quick start (inside Linux)
```sh
tools/record/record display-up                       # Xvfb :99 @ 1440x900
tools/record/record run -- /opt/workbooks/workbooks-browser
tools/record/record start out.mp4                     # x11grab (or GPU kmsgrab / Wayland)
#   ... drive the app (xdotool, or the embedded MCP) ...
tools/record/record stop                              # finalizes MP4
tools/record/record shot out.png                      # single still
tools/record/record gif out.mp4 out.gif               # MP4 → GIF
```

### Record a scripted flow (one command)
```sh
tools/record/record record-flow flows/example-app.flow flow.mp4
```
Brings the display up, launches the app, runs each `step`/`shot`/`wait`, stops,
and emits a sibling `.gif`. Flow grammar is documented in `flows/example-app.flow`.

### Terminal tutorials
```sh
tools/record/record term rec demo.cast -- "wb demo seed --fresh"
tools/record/record term mp4 demo.cast demo.mp4       # cast → agg GIF → MP4
```

### Animated cursor
- **Native pointer** (visible real cursor): drive with `xdotool mousemove/click`;
  `WB_REC_CURSOR=1` (default) makes ffmpeg/x11grab capture the pointer.
- **Synthetic-event drivers** (Tauri MCP / `eval_js`) move nothing visible →
  overlay a sprite along a path post-hoc:
  ```sh
  tools/record/record cursor overlay in.mp4 path.tsv out.mp4   # path.tsv: "<sec>\t<x>\t<y>[\tclick]"
  ```

## From the Mac host
```sh
WB_REC_CONTAINER=workbooks tools/record/trigger-from-mac.sh selftest
WB_REC_SSH=user@cloud-linux tools/record/trigger-from-mac.sh record-flow tools/record/flows/example-app.flow
```
Auto-detects backend (krunvm → podman → docker → ssh); override with `WB_REC_BACKEND`.

## Verify
```sh
tools/record/record selftest
```
On Linux with Xvfb+ffmpeg present: makes a real ~2s synthetic capture (xterm/xeyes)
→ `selftest.mp4` + `selftest.png` + `selftest.gif` in `./.rec`. Otherwise (e.g. the
Mac host, where X11 capture cannot run by design) it does a **dep-check + dry-run**
and says so honestly.

## Env knobs (see `lib/common.sh`)
`WB_REC_DISPLAY` (`:99`), `WB_REC_W`/`WB_REC_H` (`1440`×`900`), `WB_REC_FPS` (`30`),
`WB_REC_DEPTH` (`24`), `WB_REC_CRF` (`20`), `WB_REC_OUT` (`./.rec`),
`WB_REC_STATE` (`/tmp/wb-rec.json`), `WB_REC_CURSOR` (`1`).

## Capture backends, in preference order
1. **GPU `kmsgrab` → `h264_vaapi`** when a DRM device is present + permitted (cloud Linux with GPU).
2. **`x11grab` → `libx264`** (the portable default; works under Xvfb everywhere).
3. **Wayland `wf-recorder`** when `WAYLAND_DISPLAY` is set.

## Composition with the driver/proof-loop harness (`record.mjs`)
This dir has **two complementary halves**:
- **`record` (this rig, sh)** — *capture* on Linux: Xvfb display, x11grab/kmsgrab/Wayland
  → MP4 + stills + GIF, cursor overlay, terminal tutorials. Phase 1.
- **`record.mjs` (Node)** — *drive + verify*: emits intents to the app (embedded MCP)
  or web (Playwright), then runs the Gemini→MiniMax proof cascade. Phases 3–4.

They compose by **convention**: when driving the real app over MCP, `record.mjs`
looks for a sibling MP4 at `<outDir>/<take>.mp4` produced by this rig (see
`record.mjs` ~L95 and `recipes/app-demo.example.json` `_note`). So an app take is:
```sh
# 1. start Linux capture (this rig) targeting the take's expected path
tools/record/record display-up
tools/record/record run -- /opt/workbooks/workbooks-browser
tools/record/record start "$OUT/take-1.mp4"
# 2. drive + verify (the Node harness) — it picks up take-1.mp4 for the verifier
node tools/record/record.mjs recipes/app-demo.example.json --backend mcp --out "$OUT"
# 3. stop capture
tools/record/record stop
```
The Playwright web lane records its own WebM internally, so for `--backend
playwright` you don't need this rig — use it for the **app/Linux** lane and for
GIF/stills/terminal artifacts.

## Where this sits in the larger plan
This is **Phase 1** of `RECORDING-SYSTEM-FINDINGS.md` (native/Linux capture rig).
Downstream phases — demo seed (`wb demo seed`), the Gemini-video proof loop, the
web-walkthrough Playwright lane, regression-assert mode, and the Nexus
`Workbooks.Browse` CDP-over-broker provider — consume this rig's MP4/PNG outputs
and the same intent seam. The keystone shared dependency for *driving the shipped
app* is the embedded-MCP JS bridge (**wb-aakl.23**); until it lands, drive the
Linux build with `xdotool` (as the example flow does) or the web lane.
