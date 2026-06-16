# ffmpeg — trim a video (cut to a time range)
0.1.0
Use when you have a video and need a slice — first N seconds, between two timestamps, or remove the intro/outro. Stream-copy fast path vs re-encode precise path.

# When to use this
NETWORK: no
DESTRUCTIVE: no

  Need a shorter slice of an existing video. Two flavors:

  1. *Fast (stream copy):* keyframe-aligned cut, no re-encode,
     finishes in seconds regardless of source length. Output
     boundaries snap to the nearest keyframe (typically ±2s).
  2. *Precise (re-encode):* frame-accurate cut, slower because
     it re-encodes. Necessary when you need a clip starting/
     ending at a specific frame.

  NOT for: concatenating multiple clips (`[concat](concat.md)`);
  re-encoding without trimming ([transcode-to-h264](transcode-to-h264.md)).

# Workflow

## Fast (stream-copy) — first 30 seconds

## verify input
```bash
  test -f "$1" || { echo "input file $1 not found"; exit 1; }
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"
```

## keyframe-aligned trim, no re-encode (very fast)
```bash
  ffmpeg -ss 0 -i input.mp4 -t 30 -c copy out.mp4
  # -ss 0  = start (before -i = fast seek; tolerated drift up to GOP boundary)
  # -t 30  = duration in seconds
  # -c copy = no re-encode
```

## Fast — between two timestamps

## clip from 1m15s to 2m00s without re-encoding
```bash
  ffmpeg -ss 75 -i input.mp4 -to 120 -c copy clip.mp4
  # NOTE: -to here is relative to INPUT timeline, not output
```

## Precise (re-encode) — frame-accurate cut

## precise — -ss AFTER -i decodes every frame up to T (slow but exact)
```bash
  ffmpeg -i input.mp4 -ss 75 -to 120 \
    -c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p \
    -c:a aac -b:a 128k \
    -movflags +faststart \
    clip.mp4
```

## confirm the output duration matches the cut
```bash
  test -f "$1" || { echo "output missing"; exit 1; }
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"
  # should print ~45.0 for the 75→120 range
```

# Common pitfalls

  1. *Stream-copy + black frames at start.* Fast cut starts at the
     nearest keyframe AT OR BEFORE your -ss timestamp. If the video
     opens with black, you may see extra black at the start. Use
     re-encode to land exactly at -ss.

  2. *-to vs -t.* `-t` is a duration in seconds; `-to` is an absolute
     timestamp. Confuse them and the clip is the wrong length.

  3. *-ss position matters HUGELY for speed.* Before `-i` = fast
     seek (jump to keyframe + decode forward). After `-i` = slow
     seek (decode every frame from 0). 10-minute video, `-ss 540`:
     before-i is ~0.5s, after-i is ~15s.

  4. *Audio drift after fast cut.* When the audio codec doesn't align
     to keyframes (most don't), stream-copy can desync ~50-100ms.
     If sync matters, re-encode at least the audio (`-c:a aac`).

  5. *Re-encoding without `-pix_fmt yuv420p`.* Same gotcha as
     [transcode-to-h264](transcode-to-h264.md) — some pixel formats won't play in Safari/iOS.

# Verification checklist

  - [ ] Output file exists + non-zero duration
  - [ ] Duration matches expectations (ffprobe shows ~T)
  - [ ] If audio: no perceptible desync vs source
  - [ ] If browser-target: plays in Safari (yuv420p)

# See also

  - [concat](concat.md) — stitch multiple trims together
  - [transcode-to-h264](transcode-to-h264.md) — re-encode without trimming
