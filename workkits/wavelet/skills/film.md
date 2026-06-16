# wavelet — film an edit-state timeline

# When to use this
NETWORK: no
DESTRUCTIVE: no

  You have a SEQUENCE of states — not one animated composition — and
  want a demo video of the ladder. The canonical case: an in-nexus
  agent edited a workbook across several steps (empty → title →
  sections → content) and wants to *film its own edits*. Each state is
  an HTML snapshot the agent already authored; `wavelet film` turns the
  ordered snapshots into a captioned, crossfaded mp4 — ENTIRELY
  in-nexus (no host browser, no real-UI pixels).

  Use `render` instead when you have ONE composition that animates with
  CSS over time. Use `film` when you have N discrete *states*.

# The command

## film a timeline to an mp4 (1280×720, 30fps, 0.4s crossfade)
```bash
  wavelet film timeline.json -o demo.mp4
```

## narrated, custom size / pacing
```bash
  wavelet film timeline.json -o demo.mp4 \
    --w 1280 --h 720 --fps 24 --crossfade 0.4 --audio narration.mp3
```

  Flags:
  - `-o / --out` — output mp4 path (required, must end in `.mp4`).
  - `--w / --h` — frame size in px (default 1280×720).
  - `--fps` — frames per second (default 30).
  - `--crossfade` — seconds of dissolve BETWEEN steps (default 0.4;
    `0` = hard cut).
  - `--audio` — an `mp3`/`aac`/`wav` narration track, muxed as AAC.
    NOT `.m4a` (the ISO-BMFF container is not decodable in-guest).

# The timeline.json

  An ordered array (or `{"steps":[...]}`), one entry per state:

```json
  [
    { "snapshot_file": "step-0.html", "label": "Empty workbook",        "hold_secs": 1.8 },
    { "snapshot_file": "step-1.html", "label": "Add the title",         "hold_secs": 2.2 },
    { "snapshot_file": "step-2.html", "label": "Add three sections",    "hold_secs": 2.4 },
    { "snapshot_file": "step-3.html", "label": "Fill with launch tasks", "hold_secs": 3.0 }
  ]
```

  - `snapshot_file` — an HTML file beside the timeline (its whole dir is
    staged into the sandbox, so relative `<img>` assets resolve). Use
    `snapshot_html` for an inline string instead; inline wins if both set.
  - `label` — the on-screen caption (brand-green accent pill,
    bottom-left). Author/agent text, HTML-escaped. Empty ⇒ no caption.
  - `hold_secs` — how long this state holds (default 2.0). Each snapshot
    paints at the animation clock =t=0= — a snapshot is a STATE, not an
    animation.

# How an agent gets the snapshots (the natural source)

  A nexus agent does NOT need a screen recorder — it authored every
  state. After each workbook edit:
  - the workbook HTML on disk = the `snapshot_file` (current state),
  - the agent's own `_steps.jsonl` row description = the `label`.

  So filming is a capture-on-edit policy over machinery that already
  exists. The full loop (timeline → narrate → film → vision-verify →
  R2) is proven end-to-end in
  `tools/record/evals/in-nexus-workbook/` — see
  `tools/record/IN-NEXUS-FILMING.md`.

# Verify the output

## confirm a real mp4 with a video (and, if narrated, audio) stream
```bash
  test -f "$1" || { echo "film missing"; exit 1; }
  head -c 8 "$1" | tail -c 4 | grep -q ftyp || { echo "not an mp4"; exit 1; }
  echo "✓ filmed $1"
```

  For a real demo, gate it with a vision check before sharing —
  =node tools/record/lib/verify-only.mjs --video demo.mp4
  --expected-file expected.txt= (require `pass`).

# Gotchas

  - It's STATES, not motion: each snapshot is painted once at =t=0.
    There is no per-snapshot animation — pace with `hold_secs` and soften
    cuts with `--crossfade`.
  - Cost scales with total frames = Σ(`fps×hold_secs`) + crossfade
    frames. Many long holds at 1080p = a lot of frames; start small.
  - No JS runtime in the snapshots — they must look right STATICALLY.
  - Narration must be `mp3`/`aac`/`wav`; an `.m4a` input fails the
    in-guest encode.

# See also

  - [overview](overview.md) — the whole verb surface
  - [render](render.md) — one animated composition → mp4
  - [audio-sync](audio-sync.md) — building the narration track
