# The demo timeline DSL (`.org`)

One `.org` file = one demo, and the **single source of truth** for both the
driver (what to do, *when*) and the voiceover (what to say, *when*). Every cue
and every narration clip is scheduled against the same **frames↔timecode clock**
(`lib/timecode.mjs`, canonical internal unit = **frames**), so audio lands on the
on-screen action it describes instead of being spread evenly.

## Syntax

```org
#+TITLE: Workbooks Desktop — search drawer
#+TARGET: web
#+URL: http://localhost:5178/
#+FPS: 30
#+VIEWPORT: 1440x900
#+VERIFY_FRAMES: 8

* 00:00 navigate [url:http://localhost:5178/] [waitUntil:networkidle]
  Everything you've made is one keystroke away.

* 00:04 click
  Open the search drawer and it slides in from the right.
  :PROPERTIES:
  :selector: [aria-label="Search"]
  :checkpoint: a search drawer is open on the right showing a feed of file cards
  :END:

* 00:09 type [text:design]
  Start typing and it filters across files, bookmarks, and the web at once.
  :PROPERTIES:
  :selector: [placeholder="Search files, bookmarks, the web…"]
  :END:

* 00:14 screenshot [name:drawer-filtered]
  One search, every workspace.
  :PROPERTIES:
  :checkpoint: the search drawer shows results filtered by the query; no error overlay
  :END:

* 00:17 wait [ms:1500]
  No folders to dig through.
```

### Header keywords (file top)

| Keyword | Meaning | Default |
| --- | --- | --- |
| `#+TITLE:` | demo name (→ recipe name + output slug) | `Untitled demo` |
| `#+TARGET:` | `web` or `app` | `web` |
| `#+URL:` | default `navigate` URL | — |
| `#+FPS:` | frames per second (the clock) | `30` |
| `#+VIEWPORT:` | `WIDTHxHEIGHT` | `1440x900` |
| `#+VERIFY_FRAMES:` | sample count for the verify cascade | recipe default |

### Cues

Each `*` headline is a **cue**:

```
* <timecode> <intent> [key:val] [key:val] ...
  narration line(s) — spoken starting at this cue's frame
  :PROPERTIES:
  :selector: ...
  :END:
```

- **`<timecode>`** — any form `timecode.mjs` accepts: `SS`, `MM:SS`,
  `HH:MM:SS`, `HH:MM:SS:FF` (SMPTE; `FF` = whole frames), or `fN` (raw frame).
- **`<intent>`** — one of `navigate · click · type · hover · wait · screenshot ·
  eval_js · dom_read`.
- **args** — `[key:val]` inline tokens **and/or** a `:PROPERTIES:` drawer. The
  drawer wins on conflict (use it for values containing `]`, e.g. selectors).
  Recognized keys: `selector, url, x, y, text, ms, code, name, checkpoint,
  waituntil, perkeyms, timeoutms`.
- **narration** — the non-drawer body text under the headline. It is one TTS
  clip placed at this cue's frame. One narration line per cue (1:1 with cues).

## How it stays frame-accurate

1. **Driver** (`record.mjs`): cues run **sleep-to-mark** — each intent waits until
   the wall clock reaches its declared frame relative to capture start, then
   fires. If a previous intent overruns its slot the driver logs a `drift:`
   warning and fires the next immediately (no crash). The **actual landed frame**
   of every cue is written to `<take>.timing.json`:
   `[{cue, intent, declaredFrame, actualFrame, driftFrames}]`.
2. **Voiceover** (`lib/voiceover.mjs`): each narration clip is delayed by
   `toSeconds(actualFrame, fps) * 1000` ms — the **actual** landed frame, so audio
   matches where the action really happened. If two clips would overlap, the later
   is pushed to start when the earlier ends (warned). The track is `apad`/`atrim`'d
   to the exact video duration; the mux uses **no `-shortest`** (video is the
   master length — every frame kept).

## Running

```sh
# org lane (frame-accurate) — voiceover by cue frame, then verify:
./pipeline recipes/desktop-search-drawer.md --voiceover recipe

# JSON recipes still work unchanged (even-spread voiceover, afterMs dwell).
./pipeline recipes/app-demo.example.json
```

The pipeline detects `.org`, parses via `lib/dsl.mjs`, runs the scheduled driver,
voices by cue frame (passing `--timing <take>.timing.json --fps`), and verifies.

## Self-test

```sh
node lib/timecode.mjs   # round-trips every timecode form at fps 24/30/60
node lib/dsl.mjs recipes/desktop-search-drawer.md   # prints parsed timeline
```

## Frame-accuracy caveat (honest)

Cue *firing* is frame-exact (observed **0-frame** declared-vs-actual drift on all
four desktop demos, because each intent finishes well inside its slot). But for
**animated** results — e.g. a drawer that slides in — the pixels finish settling
~1 s *after* the click fires. That trailing settle is when the narration about it
plays, so it reads correctly; just don't expect the fully-rendered end-state at
the exact cue frame. Live-capture drift is bounded by how far an intent overruns
its slot; if that ever exceeds one frame the driver logs it.
