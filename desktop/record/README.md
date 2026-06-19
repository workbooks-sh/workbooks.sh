# desktop/record — the demo-recording toolkit

Records the Workbooks desktop app into a polished product clip. A demo is **one
`.work` file** — a frame-accurate timeline where prose narrates and `cue` blocks
drive the app. This is the **work-aligned** recorder (the old `.org` timeline lane
is retired with the rest of org-mode).

## A demo is a `.work` timeline

```
# Workbooks — product showcase

demo :product-showcase do
  target: web
  url: http://localhost:5178/
  fps: 30
  viewport: 1440x900
end

cue "00:00", :navigate do
  One window, every workspace you run.
  url: http://localhost:5178/
  wait_until: networkidle
end

cue "00:02", :click do
  Four real businesses, one menu.
  selector: button[aria-label^="Switch workspace"]
  checkpoint: the workspace switcher menu is open
end
```

- **`demo :slug do … end`** — header. Body keys: `title` (optional; the `#`
  heading is a fallback), `target` (`web` | `app`), `url`, `fps`, `viewport`,
  `verify_frames`.
- **`cue "<timecode>", :<intent> do … end`** — one action, scheduled against the
  frame clock (`SS`, `MM:SS`, `HH:MM:SS:FF`, or `fN`). Intents: `navigate · click ·
  rightclick · type · hover · move · drag · wait · screenshot · eval_js · dom_read`.
- **Cue body** — prose lines are the **narration** spoken from that cue's frame.
  `key: value` lines (value raw to end-of-line, so selectors survive verbatim) set
  the action: `selector`, `to`, `text`, `url`, `ms`, `code`, `x`, `y`, `name`,
  `checkpoint`, `wait_until`, `per_key_ms`, `timeout_ms`.

The clock is the single source of truth: cues fire **sleep-to-mark** (each waits
until the wall clock reaches its frame), and the voiceover lands each narration
clip on the frame the action actually landed (`<take>.timing.json`).

## Run it (macOS, web target)

The `web` target drives the desktop preview through Playwright — no Linux needed.

```sh
cd desktop && bun run dev          # the app on :5178 (mock providers)
node record/record.mjs record/recipes/product-showcase.work --no-verify --out /tmp/out
#   → /tmp/out/<slug>-take1.webm  (Playwright video; convert to mp4 with ffmpeg)
```

- `--no-verify` skips the Gemini→MiniMax checkpoint cascade (which needs API keys).
  Drop it to gate the take against each cue's `checkpoint:`.
- `--backend playwright|mcp|auto` — `web` recipes use Playwright; the Tauri `app`
  target is driven over MCP (Linux capture rig).

## Layout

```
record/
  record.mjs            driver + proof loop (sleep-to-mark pacing, take retries)
  lib/dsl.mjs           the .work timeline parser
  lib/timecode.mjs      frames↔timecode clock
  lib/backend-playwright.mjs   web backend (records video, visible cursor)
  lib/backend-mcp.mjs   app backend (drives the native Tauri build)
  lib/verify*.mjs       the verify cascade (checkpoint → verdict)
  lib/voiceover.mjs     frame-accurate TTS narration track
  recipes/*.work        the demo timelines
```
