# ffmpeg — image ops (quick-start index)
0.2.0
Entry point for still-image work with ffmpeg (PNG/JPG/WEBP/AVIF) — resize, crop, pad, convert, tile, slice, overlay. ffmpeg is THE image tool; do NOT hand-roll python/PIL. Each operation has its own deep skill; this is the map + the one-liners to get moving.

# When to use this
NETWORK: no
DESTRUCTIVE: no

  You have a still image (PNG/JPG/WEBP/AVIF) and need to transform it
  — most often to prep a rendered slide/creative for VISION review.
  ffmpeg is the toolkit for this. There is *no separate image binary
  and no need for python/PIL*. If a task seems to need python for
  image work, that's a missing-tool gap to flag, not a workaround.

  This file is the INDEX. Each operation has a deep skill with the
  full recipes, gotchas, and verification — jump to it via *See also*.

  NOT for: grabbing a still FROM a video
  ([extract-thumbnail](extract-thumbnail.md)); re-encoding VIDEO
  ([transcode-to-h264](transcode-to-h264.md)).

# First, read metadata (no ffmpeg needed)

## dims / pixel format / codec of an image
```bash
  ffprobe -v error -show_entries stream=width,height,pix_fmt,codec_name -of csv=p=0 in.png
```

# The map — pick your operation

  | Need                                   | Deep skill                  |
  |----------------------------------------|-----------------------------|
  | scale / downscale (vision ≤1568, box)  | [image-resize](image-resize.md)              |
  | crop a region / pad-letterbox to aspect| [image-crop-pad](image-crop-pad.md)            |
  | convert png/jpg/webp/avif (+ alpha/q)  | [image-convert](image-convert.md)             |
  | grid montage / contact sheet / slice   | [image-tile-montage](image-tile-montage.md)        |
  | overlay logo/watermark, alpha blend    | [image-overlay-composite](image-overlay-composite.md)   |

# The one-liners (start here, deep skill for the gotchas)

## downscale long edge to ≤1568, keep aspect, never upscale → [image-resize](image-resize.md)
```bash
  ffmpeg -i in.png -vf "scale='min(1568,iw)':-2" out.png
```

## centered square crop = the shorter edge → [image-crop-pad](image-crop-pad.md)
```bash
  ffmpeg -i in.png -vf "crop='min(iw,ih)':'min(iw,ih)'" square.png
```

## letterbox any image into a 1080×1080 box, black bars → [image-crop-pad](image-crop-pad.md)
```bash
  ffmpeg -i in.png -vf "scale=1080:1080:force_original_aspect_ratio=decrease,pad=1080:1080:-1:-1:color=black" out.png
```

## png → high-quality jpg (no alpha!) → [image-convert](image-convert.md)
```bash
  ffmpeg -i in.png -q:v 2 -pix_fmt yuvj420p out.jpg
```

## 4 images → 2×2 grid → [image-tile-montage](image-tile-montage.md)
```bash
  ffmpeg -i a.png -i b.png -i c.png -i d.png -filter_complex "tile=2x2" grid.png
```

## logo bottom-right with 10px margin (BASE first!) → [image-overlay-composite](image-overlay-composite.md)
```bash
  ffmpeg -i base.png -i logo.png -filter_complex "overlay=W-w-10:H-h-10" out.png
```

# The five gotchas that bite everyone (full lists in each deep skill)

  1. *Accidental upscale.* =scale=1568:-2= ENLARGES a small image. Use
     `scale`'min(1568,iw)':-2= when the cap must never grow it.
  2. *JPG has no alpha.* Transparent PNG → JPG flattens to BLACK.
     Keep PNG/WEBP/AVIF for alpha, or flatten onto a chosen color.
  3. *Overlay input order.* BASE image FIRST, overlay SECOND — else
     the canvas shrinks to the overlay's size.
  4. *No webp encoder in many builds.* `out.webp` can fail with
     "encoder disabled". Probe `ffmpeg -encoders | grep webp` first.
  5. *Odd dimensions.* Use `-2` in `scale` (even rounding); a `-1`
     that yields an odd size also makes `tile` drop to one cell.

# Verification (universal)

  - [ ] Output exists + `file` reports a real image type
  - [ ] Dimensions are what you intended (`ffprobe` width/height)
  - [ ] No accidental upscale on a capped edge
  - [ ] Alpha preserved (or intentionally flattened) per format
  - [ ] See the operation's deep skill for its specific checklist

# See also

  - [image-resize](image-resize.md) · [image-crop-pad](image-crop-pad.md) · [image-convert](image-convert.md) · [image-tile-montage](image-tile-montage.md) · [image-overlay-composite](image-overlay-composite.md)
  - [extract-thumbnail](extract-thumbnail.md) — pull a still FROM a video (not image-to-image)
  - [overview](overview.md) — the -i / filter argument-order gotcha
