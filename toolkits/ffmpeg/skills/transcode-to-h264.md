# ffmpeg — transcode to H.264 (browser/streaming compat)

# When to use this
NETWORK: no
DESTRUCTIVE: no

  Source video is in an exotic codec / container (HEVC, AV1,
  ProRes, MKV, MOV) and you need it as an `mp4` with H.264
  video + AAC audio for browser playback or general
  distribution.

  H.264 in mp4 is the lowest-common-denominator format —
  works in every browser, every player, every CDN.

# Workflow

## 1. inspect what you're starting with
```bash
  test -f "$1" || { echo "input $1 not found"; exit 1; }
  ffprobe -v error -show_streams -select_streams v:0 "$1" \
    | grep -E "codec_name|width|height|pix_fmt" | head
```

## 2. standard transcode — sensible defaults
```bash
  ffmpeg -i input.mov \
    -c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p \
    -c:a aac -b:a 128k \
    -movflags +faststart \
    output.mp4
  # -crf 23     : quality (18=visually lossless, 23=default, 28=lower)
  # -preset     : encode speed/efficiency tradeoff
  # -pix_fmt    : yuv420p is the only browser-safe pixel format
  # -movflags +faststart : moov atom at start = streaming-friendly
```

## 3. shrink dimensions while transcoding (e.g. 1080p ceiling)
```bash
  ffmpeg -i input.mov \
    -vf "scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease" \
    -c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p \
    -c:a aac -b:a 128k -movflags +faststart \
    output_1080p.mp4
```

## confirm the output plays
```bash
  test -f "$1" || { echo "output missing"; exit 1; }
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" \
    | awk '$1 + 0 > 0 { print "✓", $1, "seconds"; exit } END { print "✗ zero-duration output"; exit 1 }'
```

# Gotchas

  - `-pix_fmt yuv420p` is critical. Without it, some sources
    (4:4:4, 10-bit) produce output that won't play in Safari /
    iOS. Always include it when targeting browsers.
  - `-movflags +faststart` moves the metadata to the start of
    the file. Without it, the video can't start playing in a
    browser until fully downloaded.
  - For audio-only sources (no video stream), this command
    fails. Use [extract-audio](extract-audio.md) instead.
  - On Apple Silicon, `-c:v h264_videotoolbox` can be much
    faster but produces larger files at the same quality.
    Default to `libx264` for quality, swap to videotoolbox for
    speed.

# See also

  - [extract-thumbnail](extract-thumbnail.md) — single still frame
  - [extract-audio](extract-audio.md) — audio-only extraction
