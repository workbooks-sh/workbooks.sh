# ffmpeg — crop & pad an image (region, center, letterbox to aspect)
0.1.0
Use when you need to cut a rectangular region out of an image (crop=w:h:x:y, centering math) OR add bars to fit a target aspect (pad / letterbox / pillarbox). Covers the crop-is-post-scale ordering gotcha and pad color.

# When to use this
NETWORK: no
DESTRUCTIVE: no

  You have a still image and need to change its FRAMING without
  squashing it:
  - *crop* — keep a sub-rectangle (cut a region, make a square,
    trim a margin).
  - *pad* — add bars so the image fits an exact aspect/box
    (letterbox ` horizontal bars, pillarbox ` vertical bars).

  ffmpeg is the image tool — *do not hand-roll python/PIL*.

  NOT for: changing the pixel SIZE while keeping the whole image
  ([image-resize](image-resize.md)); changing the FORMAT
  ([image-convert](image-convert.md)). Read current dims first:
  =ffprobe -v error -show_entries stream=width,height -of csv=p=0 in.png=.

# Crop — keep a rectangle

  =crop=W:H:X:Y= → output is W×H, with its top-left corner taken
  from (X,Y) measured from the SOURCE top-left. Y grows downward.

## verify input + read dims
```bash
  test -f "$1" || { echo "input file $1 not found"; exit 1; }
  ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$1"
```

## crop a 600×400 region whose top-left is (100,50)
```bash
  ffmpeg -i in.png -vf crop=600:400:100:50 out.png
```

## Centering math

  Omit X and Y entirely and ffmpeg centers the crop automatically —
  this is the simplest and least error-prone form:

## centered 600×400 crop (ffmpeg computes X,Y)
```bash
  ffmpeg -i in.png -vf crop=600:400 out.png
```

  If you need the offset explicit (e.g. to nudge), the centering
  formula is `X`(iw-W)/2=, `Y`(ih-H)/2= using the input-dim
  variables:

## explicit centered crop using iw/ih
```bash
  ffmpeg -i in.png -vf "crop=600:400:(iw-600)/2:(ih-400)/2" out.png
```

## Center-crop to a square (= the shorter edge)

## square crop from the center, side = min(iw,ih)
```bash
  ffmpeg -i in.png -vf "crop='min(iw,ih)':'min(iw,ih)'" square.png
```

## Trim a fixed margin off every edge

## shave 20px from all four sides
```bash
  ffmpeg -i in.png -vf "crop=iw-40:ih-40:20:20" trimmed.png
```

# Pad — add bars to reach an aspect / box

  =pad=W:H:X:Y:color= places the (smaller) image at (X,Y) inside a
  W×H canvas and fills the rest with `color`. The image is NOT
  scaled by pad — pad only adds canvas. *W and H must be ≥ the input
  dims* or ffmpeg errors with "Padded dimensions cannot be smaller
  than input dimensions."

## Letterbox/pillarbox to an exact box (the robust pattern)

  The reliable recipe is *scale-to-fit-inside THEN pad to the box*.
  `scale`...:force_original_aspect_ratio=decrease= guarantees the
  scaled image is ≤ the box on both axes, so the following pad never
  hits the "smaller than input" error. `-1:-1` for pad's X/Y centers
  the image.

## fit any image into a 1080×1080 square, centered, black bars
```bash
  ffmpeg -i in.png -vf "scale=1080:1080:force_original_aspect_ratio=decrease,pad=1080:1080:-1:-1:color=black" out.png
```

## fit into 1920×1080 (16:9), white bars
```bash
  ffmpeg -i in.png -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:-1:-1:color=white" out.png
```

  Wide source → 16:9 box gives horizontal bars top/bottom
  (letterbox). Tall source → bars left/right (pillarbox). The single
  recipe handles both because pad centers whatever it's given.

## Pad to an aspect ratio without a fixed pixel box

  When you want "make it 16:9 by adding the minimum bars, keep
  current resolution" — compute the target dim from the source.
  Pad height to make width:height = 16:9 (letterbox a wide-enough
  image), clamping so you never shrink:

## pad height so the frame becomes ≥16:9 (centered, black)
```bash
  ffmpeg -i in.png -vf "pad='iw':'max(ih,iw*9/16)':(ow-iw)/2:(oh-ih)/2:black" out.png
```

## pad width to make it 16:9 (pillarbox a tall image)
```bash
  ffmpeg -i in.png -vf "pad='max(iw,ih*16/9)':'ih':(ow-iw)/2:(oh-ih)/2:black" out.png
```

  Here `ow` / `oh` are the pad OUTPUT dims, so `(ow-iw)/2` centers
  the source horizontally and `(oh-ih)/2` vertically.

## confirm output dims + that it's a real image
```bash
  test -f "$1" || { echo "output missing"; exit 1; }
  file "$1" | grep -qE "PNG|JPEG|WebP|AVIF" || { echo "not an image"; exit 1; }
  ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$1"
```

# The crop-is-post-scale ordering gotcha

  Filters in a `-vf` chain run *left to right*. If you both scale and
  crop, the order changes the meaning:

  - `scale`...,crop=...= → scale FIRST, then crop the scaled image.
    The crop X:Y:W:H are in the SCALED coordinate space.
  - `crop`...,scale=...= → crop the original, then scale the cutout.

  Picking the wrong order is the classic "my crop coordinates are
  off" bug. Decide which coordinate space your numbers are in:

## scale to 1000 wide, THEN crop a 1000×600 band from y=200 (scaled space)
```bash
  ffmpeg -i in.png -vf "scale=1000:-2,crop=1000:600:0:200" out.png
```

## crop the original region FIRST, then downscale the cutout
```bash
  ffmpeg -i in.png -vf "crop=600:400:100:50,scale=300:-2" out.png
```

# Color for pad

  `color` accepts named colors (`black`, `white`, `red`), `0xRRGGBB`
  hex, or `RRGGBB@A` with an alpha float (e.g. `000000@0.0` for
  transparent — only meaningful for formats with alpha like PNG).
  Default is black.

## brand-grey bars via hex
```bash
  ffmpeg -i in.png -vf "scale=1080:1080:force_original_aspect_ratio=decrease,pad=1080:1080:-1:-1:color=0x111418" out.png
```

## transparent pad (PNG only — keeps alpha, no visible bars)
```bash
  ffmpeg -i in.png -vf "scale=1080:1080:force_original_aspect_ratio=decrease,pad=1080:1080:-1:-1:color=black@0.0" out.png
```

  Note: a transparent pad needs an alpha-capable output (PNG/WEBP/
  AVIF). On JPG the alpha is dropped and the pad shows as black —
  see [image-convert](image-convert.md) for the alpha-loss rule.

# Common pitfalls

  1. *Pad smaller than input.* =pad=800:600= on a 1000px-wide image
     errors. Pad can only ADD canvas. Scale-to-fit FIRST (the
     =force_original_aspect_ratio=decrease,pad= pattern) so the pad
     box is always ≥ the (scaled) image.
  2. *crop X:Y is from the TOP-LEFT, not center.* And a crop that runs
     past the edge (X+W > iw) errors. Either omit X:Y to auto-center,
     or clamp against the dims you read with `ffprobe`.
  3. *Scale/crop order.* `scale,crop` ≠ `crop,scale`. Crop
     coordinates are interpreted in the space of whatever ran before
     it (post-scale if scale came first).
  4. *Pad color on JPG.* A transparent (`@0.0`) pad becomes black when
     written to JPG (no alpha channel). Use PNG/WEBP/AVIF for see-
     through padding.
  5. *Odd pad/crop dims for video.* If this feeds an h264 pipeline,
     keep W and H even (crop to even sizes; pad targets even). For
     pure PNG/JPG it's a non-issue.
  6. *Quoting expressions.* Anything with `min`, `max`, `iw`, `/` must
     be quoted so the shell doesn't split on the parens/commas.

# Verification checklist

  - [ ] Output exists + `file` reports a real image type
  - [ ] crop: output dims == W×H requested; region is the one intended
  - [ ] pad: output dims == target box / aspect; image centered
  - [ ] pad bars are the requested color (and not unexpectedly black
        from a JPG alpha drop)
  - [ ] If scale+crop: coordinates match the chosen pre/post-scale space

# See also

  - [image-resize](image-resize.md) — scale/downscale (the step that usually precedes pad)
  - [image-convert](image-convert.md) — format change + the alpha-loss rule for JPG
  - [image-overlay-composite](image-overlay-composite.md) — placing one image on top of another
  - [image-ops](image-ops.md) — quick-start index for all image transforms
  - =ffmpeg -h filter=crop= / =ffmpeg -h filter=pad= for full args
