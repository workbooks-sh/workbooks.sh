# ffmpeg

A skill-driven wrapper around the standard `ffmpeg` binary, covering image, audio, and video at parity. ffmpeg is powerful but the flag surface is large and the order of `-i` and filter args matters — the skills are end-to-end recipes for the common operations an agent reaches for, plus the per-pixel-format gotchas that bite when you only skim `--help`.

## When to reach for it

Reach for `ffmpeg` for any still-image work (resize, crop, convert, tile, overlay) as well as video and audio — it's the image tool too. Don't hand-roll Python/PIL for image work; reach for the `image-ops` skills here.

## Example

```
# resize a still to even dimensions, capped for vision input:
ffmpeg -i in.png -vf "scale='min(1568,iw)':-2" out.png
# high-quality GIF with a generated palette:
ffmpeg -i in.mp4 -vf "fps=15,palettegen" palette.png
ffmpeg -i in.mp4 -i palette.png -lavfi "fps=15,paletteuse" out.gif
```

## What it grants

- Image: resize, crop/pad/letterbox, png↔jpg↔webp↔avif convert, tile/contact-sheet/slice, overlay/watermark/composite.
- Video: scale/crop/pad, watermark/PiP/drawtext overlay, GIF/webm export, fps/speed/timelapse, audio mux, trim, concat, transcode to h264.
- Audio: extract, replace, mix, normalize, strip.
- Thumbnails, subtitle burn-in, hardware acceleration, and a CRF/bitrate/preset mental model.

## Maturity

Stable (v0.3.0). Requires ffmpeg 6.0+. `ffmpeg --help` and `ffmpeg <verb> --help` remain authoritative for per-flag detail; the skills are task recipes, not man-page substitutes.
