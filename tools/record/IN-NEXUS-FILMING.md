# In-nexus filming — how an agent films its own workbook edits

> **Status: proven end-to-end.** A nexus agent authors a workbook across several
> real edits, films the edit timeline into a NARRATED demo video *entirely inside
> the sandbox* (no host browser, no native ffmpeg touching the video), the
> recording-toolkit VERIFY cascade gates it with a vision model, and it ships to
> R2. The runnable proof is the eval at
> [`evals/in-nexus-workbook/`](evals/in-nexus-workbook/).

This is the counterpart to the host-Playwright capture path the rest of this
toolkit uses (`backend-playwright.mjs` / `backend-mcp.mjs` → `verify.mjs`). That
path drives a **real browser** and captures **real pixels**. In-nexus filming
needs neither — the agent already *is* the author of each workbook state, so it
can replay those states into a video without ever rendering a real UI.

---

## The loop, end to end

```
  edit-state timeline ──▶ narration (host-brokered TTS) ──▶ wavelet film (in-nexus)
        │                                                          │
   each edit's snapshot                              render snapshots as full-bleed
   HTML + a label                                    scenes + captions, crossfade,
   (= a _steps.jsonl row)                            encode H.264 + mux AAC — all
                                                      in the wasm sandbox
                                                          │
                                  VERIFY cascade (lib/verify-only.mjs) ──▶ R2 upload
                                  (Gemini triage → deep → tiebreak)        wrangler r2 put
```

Five stages (the eval's `run.mjs` is exactly this):

1. **Build the edit-state timeline.** An ordered `timeline.json`, one entry per
   edit the agent made: `{ "snapshot_file": "step-N.html", "label": "...",
   "hold_secs": N }`. Each `snapshot_file` is the workbook's HTML *at that edit
   state* — empty → title → sections → content. (`snapshot_html` inline is also
   accepted; a `snapshot_file` keeps each state as a real file beside the run,
   mirroring how an agent keeps its artifacts.)
2. **Narrate (the ONE host step).** TTS each step's narration line with
   ElevenLabs (`XI_API_KEY`), then pace the clips across the film's duration into
   a single `narration.mp3` (each line begins at the *onset* of the edit-state
   hold it describes, so the voice tracks the on-screen action). This is the only
   host-brokered step — narration is a network capability, exactly like
   `web_search` / `fetch`. **Must be `.mp3`/`.aac`/`.wav`, never `.m4a`** — the
   in-guest decoder lane handles raw/elementary audio, not the ISO-BMFF
   container.
3. **`wavelet film` — in-nexus.** `wavelet film timeline.json -o demo.mp4
   --audio narration.mp3`. The render core (`render_film.wasm`, Rust→wasm32-wasip1)
   paints each snapshot full-bleed as a scene at the animation clock `t=0` (a
   snapshot is a STATE), composites the label as a brand-green caption pill,
   crossfades between edits, and writes a `frame_%05d.png` sequence. The encode
   lane (`wb_encode.wasm`, our clang.wasm-built libx264) muxes it to H.264 +
   native AAC. **No host ffmpeg, no native exec, no GPU** — the entire video is
   built in the sandbox. (Empirically: `streams = [video:h264, audio:aac]`,
   wasm imports = `wasi_snapshot_preview1` only.)
4. **Verify (the gate).** `lib/verify-only.mjs` runs the same cascade as the
   host-capture path: sample the mp4 to N frames, send them + the expected steps
   + a DOM signal to the vision models (Gemini triage → Gemini deep → MiniMax
   tiebreak, 2-of-3). A **`pass` is required** to proceed; a real `fail` blocks
   the upload (eval `run.mjs` exits 1). Missing `OPENROUTER_API_KEY` → `skip`
   (non-blocking, honestly flagged).
5. **Share.** `wrangler r2 object put workbooks-media/demos/workbook-demo.mp4
   --file demo.mp4 --remote`. Proven with a download round-trip.

Run it:

```bash
cd tools/record/evals/in-nexus-workbook
export XI_API_KEY=...            # narration (omit / --no-audio for a silent film)
export OPENROUTER_API_KEY=...    # verify (omit → verify skips, non-blocking)
export CLOUDFLARE_ACCOUNT_ID=... # + wrangler auth for the R2 upload
node run.mjs                     # full loop; --no-audio / --no-upload to scope it
```

The eval prints a manifest with each stage's verdict and writes
`out/workbook-demo.mp4` + `out/manifest.json`.

---

## Where the edit snapshots come from — for a REAL autonomous nexus agent

This is the crux: **a nexus agent does not need a screen recorder, because it
authored every state.** Look at `runtime/host/nexus.ex` (the per-tenant compute
home) and `runtime/host/agent.ex`:

- Every tool call an agent makes is appended, always-on, to
  `<workdir>/_steps.jsonl` (`Workbooks.Agent.log_step/2`). Each row is
  `{step, agent, tool, args, output, exit_code, dur_ms, ts}` — the agent's own
  description of the edit it just made. **That row *is* the film `label`.**
- The thing the agent edited — the workbook HTML — lives in the same VFS
  workdir. After an edit tool returns, the file on disk is the workbook's
  **current state**. **That file *is* the film `snapshot_file`.**

So a production "film my work" agent loop is purely a *capture-on-edit* policy
over machinery that already exists:

```
on each workbook-mutating tool call (write/edit/section/cell):
  1. copy the workbook HTML to  film/step-<n>.html          # the snapshot = current state
  2. append { snapshot_file: "step-<n>.html",
             label: <the _steps.jsonl row's human description>,
             hold_secs: 2.0 } to  film/timeline.json        # the label = what it did
at run end (or on `film my work`):
  3. (optional) narration line per step  →  narration.mp3   # host-brokered TTS
  4. wavelet film film/timeline.json -o demo.mp4 [--audio narration.mp3]
  5. wavelet-verify (or lib/verify-only.mjs) — require pass
  6. wb publish / wrangler r2 put — share the URL
```

The eval's `build-timeline.mjs` is the deterministic stand-in for step 1–2: it
emits the four kanban edit states a real agent would have captured. Swap it for
the agent's actual `_steps.jsonl` + workdir snapshots and nothing downstream
changes — the timeline shape is identical.

---

## Tradeoffs — in-nexus replay vs host-Playwright screen-capture

| | **In-nexus replay** (this doc) | **Host-Playwright capture** (`backend-playwright.mjs`) |
|---|---|---|
| What's filmed | the workbook **states the agent authored** (HTML snapshots) | the **real UI**, real pixels, real interactions |
| Sandboxing | **fully sandboxed** — render + encode + mux all in wasm (wasi-only) | needs the host browser broker (Chromium/CDP) + host ffmpeg |
| Fidelity | the document/workbook surface only; **no JS runtime**, no real-app chrome, no cursor/hover/click motion | pixel-exact: the actual app, animations, JS, the real cursor |
| Dependencies | zero host deps for the video — `render_film.wasm` + `wb_encode.wasm` | Chromium + CDP + ffmpeg on the host (the broker tier) |
| Determinism | deterministic frames (clock-driven, `t=0` per snapshot) | non-deterministic (timing, fonts, network, layout jitter) |
| Cost / where it runs | runs **inside the tenant nexus**, no broker grant | runs on a trusted host rig (the Linux capture machine) |
| Best for | **"show what the agent built"** — workbook edits, doc authoring, the state ladder | **"show the real product working"** — UI flows, clicks, live interactions |

The two are complementary, not competing:

- **In-nexus replay** is the right tool for *"film my work"* — the agent edited a
  document and wants to show the before/after ladder. It's the default because it
  needs nothing outside the sandbox and the agent already holds every input.
- **Host-capture** is the right tool when the demo's value *is* the real running
  UI (hover states, drag, JS-driven behavior, the actual app shell). That needs
  real pixels, so it needs the browser broker — see the kernel.sh browser tier in
  MEMORY.

A natural production split: an in-nexus agent ships the **edit-ladder replay**
itself (sandboxed, free, instant); when a demo genuinely needs real-UI pixels it
**files a capture request** to the host browser broker, which runs the
Playwright path and returns the mp4 — same `verify` gate, same R2 share.

---

## What a production "film my work" agent loop looks like

```
agent (in its nexus):
  ... does real work: authors / edits a workbook across N tool calls ...
  capture-on-edit policy snapshots each state → film/timeline.json   (no extra agent reasoning)

  on "film my work" (or end-of-run):
    bash> wavelet film film/timeline.json -o demo.mp4 \
            $( [ -f film/narration.mp3 ] && echo --audio film/narration.mp3 )
    bash> node $RECORD/lib/verify-only.mjs --video demo.mp4 \
            --expected-file film/expected.txt --signals-file film/signals.json
          # exit 0 (pass|skip) → proceed; exit 1 (fail) → revise & re-film
    bash> wrangler r2 object put workbooks-media/demos/<run>.mp4 --file demo.mp4 --remote
    → returns the share URL; the agent posts it back as its deliverable
```

Notes for the production loop:

- **Narration is optional and host-brokered.** Silent films need zero host
  capability. Add narration only when the share warrants a voice; it's the one
  network call (ElevenLabs), brokered like any other.
- **The verifier is the publish gate, not decoration.** Require `pass`. On a real
  `fail` the agent should read `verify.reasons` / `error_frames`, fix the offending
  edit state, and re-film — the same self-correction loop the host-capture path uses.
- **`hold_secs` is the pacing knob;** `--crossfade` softens the cut between edits
  (set `0` for hard cuts per the brand "no fade between *shots*" rule — note a
  state-to-state crossfade reads as a dissolve between document versions, which is
  acceptable here; tune to taste).
- **Everything except narration + the LLM verify call runs in-nexus.** The video
  itself never touches host ffmpeg or a host browser. That's the whole point: an
  agent can film its workbook from inside its own sandbox.
