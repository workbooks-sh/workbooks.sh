# wavelet — render to mp4

# When to use this
NETWORK: no
DESTRUCTIVE: no

  You have an HTML composition (see [scaffold-a-composition](scaffold-a-composition.md)) and want the
  final mp4. `wavelet render` does the whole pipeline in-nexus: it
  rasterizes the composition to a deterministic PNG frame sequence
  IN-SANDBOX, then the host encode broker muxes those frames into an
  h264/yuv420p mp4.

# The command

## render at defaults (1280×720, 30fps, 2s, crf 18)
```bash
  wavelet render clip.html -o out.mp4
```

## full control — size, frame rate, length, quality
```bash
  wavelet render clip.html -o out.mp4 --w 1080 --h 1920 --fps 24 --duration 6 --crf 20
```

  Flags:
  - `-o / --out` — output mp4 path (required, must end in `.mp4`).
  - `--w / --h` — frame width/height in px (default 1280×720).
  - `--fps` — frames per second (default 30). Frame count = fps×duration.
  - `--duration` — seconds (default 2).
  - `--crf` — libx264 quality, 0 (lossless) .. 51 (worst), default 18.
  - `--audio` — an mp3 to mux as an AAC track; see [audio-sync](audio-sync.md).

# Verify the output

## confirm a real h264 mp4 with non-zero duration
```bash
  test -f "$1" || { echo "render missing"; exit 1; }
  # mp4 magic: bytes 4..7 == "ftyp"
  head -c 8 "$1" | tail -c 4 | grep -q ftyp || { echo "not an mp4"; exit 1; }
  echo "✓ rendered $1"
```

# What "in-nexus" means here

  - The frame render is the SAME sandboxed wasm command lane as jq /
    grep — no native renderer, no GPU, no Node.
  - The ONLY host step is the final mux (ffmpeg cannot run in the
    guest). It is gated by the `encode` capability; a true-sandbox
    (`compute`) profile cannot encode and the render will report
    `:denied` at the mux step. The `minimal`, `network` and `posix`
    profiles grant `encode`.

# Gotchas

  - Render cost scales with `fps × duration × w × h` — a 30fps × 10s
    × 1080p clip is 300 large frames. Start small (=--w 320 --h 180
    --fps 12=) while iterating, then scale up for the final.
  - The composition is animated with CSS `@keyframes` only; if nothing
    moves, check your `animation` properties (no JS runtime exists).
  - Relative assets must sit beside the composition file — the whole
    directory is staged into the sandbox.

# See also

  - [scaffold-a-composition](scaffold-a-composition.md) — author the HTML first
  - [transitions](transitions.md) — sequence multiple sections in one clip
  - [audio-sync](audio-sync.md) — add a soundtrack
