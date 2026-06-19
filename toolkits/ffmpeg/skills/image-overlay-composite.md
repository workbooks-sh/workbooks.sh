# ffmpeg — overlay & composite (watermark, logo, alpha blend)
0.1.0
Use to place one image on top of another — logo/watermark in a corner, centered badge, alpha-blended stamp. Covers overlay=x:y with main_w/overlay_w positioning math, scale-then-overlay, semi-transparent watermarks, and the input-order gotcha (base image FIRST).

# When to use this
NETWORK: no
DESTRUCTIVE: no

  You have a BASE image and want to stamp something ON TOP of it: a
  logo in the corner, a semi-transparent watermark, a badge, a
  "before/after" label. The `overlay` filter composites a second
  input over the first, honoring the top image's alpha.

  ffmpeg is the image tool — *do not hand-roll python/PIL*.

  NOT for: arranging images side-by-side in a grid
  ([image-tile-montage](image-tile-montage.md) — that's `tile`/`hstack`, no
  layering); a single resize/crop/pad
  ([image-resize](image-resize.md) / [image-crop-pad](image-crop-pad.md)).

  This is a TWO-input filter, so it always needs `-filter_complex`
  (not `-vf`) and two `-i` flags.

# The input-order gotcha (read this first)

  Order of inputs IS the layer order. The FIRST `-i` is the BASE
  (bottom, defines the output canvas size); the SECOND is what's
  drawn on top:

```
  ffmpeg -i BASE.png -i TOP.png -filter_complex "overlay=X:Y" out.png
                ^bottom    ^top
```

  Swap them and the output canvas becomes the LOGO's size (e.g.
  60×60) with the background cropped to it — the classic "my whole
  image disappeared, I just see the logo" bug. The base image goes
  first, every time.

  In filter labels `[0:v]` is the first input, `[1:v]` the second.

# Positioning math: overlay=X:Y

  X,Y is the top-left of the OVERLAY measured from the base's
  top-left. Available variables:

  | Var          | Means                          |
  |--------------|--------------------------------|
  | `W` / `main_w` | base (output) width          |
  | `H` / `main_h` | base height                  |
  | `w` / `overlay_w` | overlay width             |
  | `h` / `overlay_h` | overlay height            |

  The canonical placements (M = margin in px):

  | Placement     | X:Y                          |
  |---------------|------------------------------|
  | top-left      | `M:M`                        |
  | top-right     | `W-w-M:M`                     |
  | bottom-left   | `M:H-h-M`                     |
  | bottom-right  | `W-w-M:H-h-M`                |
  | centered      | `(W-w)/2:(H-h)/2`            |

## verify both inputs exist
```bash
  test -f "$1" || { echo "base $1 not found"; exit 1; }
  test -f "$2" || { echo "overlay $2 not found"; exit 1; }
```

## logo bottom-right with a 10px margin
```bash
  ffmpeg -i base.png -i logo.png -filter_complex "overlay=W-w-10:H-h-10" out.png
```

## centered badge
```bash
  ffmpeg -i base.png -i badge.png -filter_complex "overlay=(W-w)/2:(H-h)/2" out.png
```

## confirm output kept the BASE dimensions (not the overlay's)
```bash
  test -f "$1" || { echo "output missing"; exit 1; }
  file "$1" | grep -qE "PNG|JPEG|WebP|AVIF" || { echo "not an image"; exit 1; }
  ffprobe -v error -show_entries stream=width,height -of csv=p=0 "$1"
```

# Alpha blend — semi-transparent watermark

  A logo PNG with alpha composites at full strength by default. To
  make it SEMI-transparent (a faint watermark), multiply its alpha
  with =colorchannelmixer=aa=<0..1>= on the overlay stream first.
  =format=rgba= guarantees there's an alpha channel to scale.

## 40%-opacity watermark, bottom-right
```bash
  ffmpeg -i base.png -i logo.png \
    -filter_complex "[1:v]format=rgba,colorchannelmixer=aa=0.4[wm];[0:v][wm]overlay=W-w-10:H-h-10" \
    out.png
```

  If the source PNG has no alpha (opaque logo), this same chain adds
  one and dims it uniformly — exactly what you want for a watermark.

# Scale-then-overlay (size the logo relative to the base)

  Don't overlay a giant logo at native size — scale it FIRST in its
  own filter branch, then overlay the scaled result. Two ways:

## fixed logo size (120px wide, keep aspect)
```bash
  ffmpeg -i base.png -i logo.png \
    -filter_complex "[1:v]scale=120:-1[wm];[0:v][wm]overlay=W-w-20:H-h-20" out.png
```

## logo sized to a FRACTION of the base width (responsive)
```bash
  ffmpeg -i base.png -i logo.png \
    -filter_complex "[1:v]scale=iw*0.15:-1[wm];[0:v][wm]overlay=W-w-20:H-h-20" out.png
```

  Note: in the scale branch, `iw` refers to the LOGO's own width
  (that branch's input), not the base. To size relative to the BASE
  width you must read the base dims with `ffprobe` and substitute the
  number, since the two streams don't share variables across the
  `scale` filter.

## logo = 15% of the BASE width (resolve base dims first)
```bash
  read -r BW BH < <(ffprobe -v error -show_entries stream=width,height -of csv=p=0 base.png | tr ',' ' ')
  LW=$(( BW * 15 / 100 ))
  ffmpeg -i base.png -i logo.png \
    -filter_complex "[1:v]scale=${LW}:-1[wm];[0:v][wm]overlay=W-w-20:H-h-20" out.png
```

# The color-shift / format gotcha

  The overlay filter's default output `format` is `yuv420` — fine for
  VIDEO, but when compositing RGB STILLS it can shift colors and DROP
  the base's alpha. For image work, force RGB-friendly handling:

## keep RGB/alpha through the composite (still images)
```bash
  ffmpeg -i base.png -i logo.png \
    -filter_complex "overlay=W-w-10:H-h-10:format=auto" out.png
```

  =format=auto= lets ffmpeg keep an RGBA pipeline so a transparent
  base stays transparent and colors don't get a YUV round-trip. (When
  the FINAL output is JPG you'll lose alpha anyway — JPG has none; see
  [image-convert](image-convert.md).)

  Halos / dark edges around an overlaid logo usually mean a
  premultiplied-vs-straight alpha mismatch — try
  `overlay`...:alpha=premultiplied= (or `straight`) to match the
  source.

# Common pitfalls

  1. *Inputs in the wrong order.* BASE first, TOP second. Reversed →
     the output canvas shrinks to the overlay's size. This is the #1
     overlay bug.
  2. *Using `-vf` for overlay.* overlay is a 2-input filter; it needs
     `-filter_complex` and two `-i`. `-vf` (single-stream) can't
     reference `[1:v]`.
  3. *Logo too big.* Overlaying at native size dwarfs the base. Scale
     the overlay branch first (`[1:v]scale`...[wm]=).
  4. *No alpha to blend.* =colorchannelmixer=aa= needs an alpha
     channel — prefix =format=rgba= so it exists.
  5. *YUV color shift on stills.* Add =:format=auto= to overlay for
     image (RGB) work so colors/alpha survive.
  6. *`iw` in the scale branch is the LOGO's width*, not the base's.
     For base-relative sizing, read base dims with `ffprobe` and pass
     a number.
  7. *Positioning off by the margin sign.* `W-w-M` (subtract overlay
     width AND margin) puts it inside the right edge; forgetting `-w`
     pushes it off-canvas to the right.

# Verification checklist

  - [ ] Output exists + `file` reports a real image type
  - [ ] Output dims == the BASE dims (not the overlay's → input order)
  - [ ] Logo sits where intended (corner/center), fully on-canvas
  - [ ] Watermark opacity looks right (alpha applied, not 100% or 0%)
  - [ ] No unexpected color shift (use =:format=auto= for stills)
  - [ ] If final is PNG/WEBP/AVIF: base transparency preserved

# See also

  - [image-tile-montage](image-tile-montage.md) — arrange images side-by-side (no layering)
  - [image-convert](image-convert.md) — final format + the JPG alpha-loss rule
  - [image-resize](image-resize.md) — scale the logo (or base) before compositing
  - [image-ops](image-ops.md) — quick-start index for all image transforms
  - [subtitle-burn](subtitle-burn.md) — the video analogue (burning text/graphics into frames)
  - =ffmpeg -h filter=overlay= for the full filter args
