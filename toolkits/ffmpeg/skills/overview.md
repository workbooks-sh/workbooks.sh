# ffmpeg — overview

# When to use this
NETWORK: no
DESTRUCTIVE: no

  Reach for these skills when the agent needs to process video
  or audio: extract a thumbnail, transcode to a different
  codec/format, pull the audio track out, trim a clip, resize.

  For checking metadata only (`duration, codec, dims`), use
  `ffprobe` directly — it's simpler than `ffmpeg`:

```bash
  ffprobe -hide_banner -i input.mp4 2>&1 | head
```

# The argument-order gotcha

  ffmpeg's CLI is order-sensitive:

```
  ffmpeg [global opts] -i <input1> [in1 opts] -i <input2> [in2 opts] [filter opts] <output>
```

  Flags BEFORE `-i` apply to inputs. Flags AFTER `-i` apply to
  outputs. `-ss 30` before `-i` seeks the INPUT (fast); after
  `-i` it seeks the OUTPUT (slow). Skills always show the right
  position.

# Verify

## confirm ffmpeg is installed
```bash
  command -v ffmpeg >/dev/null || { echo "ffmpeg missing — brew install ffmpeg (macOS) or apt install ffmpeg (Linux)"; exit 1; }
  ffmpeg -version | head -1
```

# See also

  - [extract-thumbnail](extract-thumbnail.md) — single still from a video at time T
  - [transcode-to-h264](transcode-to-h264.md) — re-encode for browser/streaming compat
  - [extract-audio](extract-audio.md) — pull audio out as mp3/wav
  - [trim](trim.md) — cut a video to a time range
  - [concat](concat.md) — stitch multiple clips into one
  - [subtitle-burn](subtitle-burn.md) — bake captions in as pixels
  - [hardware-acceleration](hardware-acceleration.md) — VideoToolbox / NVENC / VAAPI
  - [lossy-tradeoffs](lossy-tradeoffs.md) — CRF, bitrate, preset, codec mental model

  When uncertain about a flag: `ffmpeg -h <topic>` (e.g.
  =ffmpeg -h encoder=libx264=).
