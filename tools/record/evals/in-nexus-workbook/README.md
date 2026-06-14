# Eval: in-nexus workbook filming

A real eval of the full **"an agent films its own workbook edits"** loop, built on
the recording-toolkit VERIFY cascade. It edits a kanban workbook across four real
states (empty → title → sections → content), captures the workbook HTML snapshot +
a label after each edit, films the timeline into a NARRATED demo video *entirely
in-nexus* (`wavelet film`), vision-verifies it (require pass), and uploads to R2.

See [`../../IN-NEXUS-FILMING.md`](../../IN-NEXUS-FILMING.md) for the full writeup
(where the snapshots come from for a real autonomous agent, the tradeoffs vs
host-Playwright capture, and the production loop).

## Run

```bash
export XI_API_KEY=...            # narration TTS (omit or --no-audio for a silent film)
export OPENROUTER_API_KEY=...    # vision verify (omit → verify skips, non-blocking)
export CLOUDFLARE_ACCOUNT_ID=... # + wrangler auth for the R2 upload

node run.mjs                     # full loop
node run.mjs --no-audio --no-upload   # build + verify only, silent
```

## Files

| File | What |
|---|---|
| `build-timeline.mjs` | emits the 4 edit-state snapshots + `timeline.json` + `expected.txt` + `narration.json` (the deterministic stand-in for an agent's `_steps.jsonl` + workdir snapshots) |
| `run.mjs` | the orchestrator: timeline → narrate → `wavelet film` → verify-only → R2 |
| `step-{0..3}.html` | the workbook HTML at each edit state (the `snapshot_file`s) |
| `timeline.json` | the ordered `[{snapshot_file,label,hold_secs}]` the film lane eats |
| `expected.txt` | the steps the demo must show (gates the vision verifier) |
| `narration.json` | one narration line per edit (input to TTS) |
| `out/` | generated artifacts (the demo mp4, manifest, signals) — gitignored |

## Proven (empirical)

- `wavelet film` produces H.264 video + AAC audio, ~10.7s, fully in-guest
  (wasm imports = `wasi_snapshot_preview1` only).
- VERIFY cascade returns **pass** (Gemini 3.5 flash, confidence 0.8 — recognized
  all four edits: empty, title, three columns, filled tasks).
- R2 upload + download round-trip of `workbooks-media/demos/workbook-demo.mp4`.
