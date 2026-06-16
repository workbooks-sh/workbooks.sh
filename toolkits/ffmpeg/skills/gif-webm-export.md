# ffmpeg — GIF · WebM/VP9 · animated WebP export
0.1.0
Use when a clip needs to ship as an animated GIF, a WebM/VP9 video, or an animated WebP — for web embeds, ad previews, README demos, or autoplay loops. Covers the palettegen/paletteuse two-pass that fixes GIF banding, fps/scale size tradeoffs, and the "huge file" traps.

# When to use this
NETWORK: no
DESTRUCTIVE: no

  A short clip needs a LOOP-FRIENDLY web format:

  - *GIF* — universal, autoplays everywhere, but huge + only 256
    colors. Use for README demos, chat, ancient embed surfaces.
  - *WebM / VP9* — far smaller than GIF at equal quality, alpha
    support, autoplays in modern browsers. The right default for
    web/ad previews when you control the surface.
  - *animated WebP* — middle ground: smaller than GIF, works as an
    `<img>` (no `<video>` tag needed), broad-but-not-total support.

  NOT for: full-length deliverables (use [transcode-to-h264](transcode-to-h264.md));
  a single still ([extract-thumbnail](extract-thumbnail.md) / [image-ops](image-ops.md)).

  The single biggest lever is *trim first* — a GIF's size scales
  with frames × resolution. Cut to the exact loop ([trim](trim.md)) BEFORE
  exporting.

# Why GIF needs two passes

  GIF is limited to a 256-color palette PER FRAME. ffmpeg's default
  single-pass GIF picks a generic 256-color web palette → visible
  *banding* on gradients and *wrong colors* on brand assets. The fix
  is a two-pass: `palettegen` analyzes the clip and builds an
  OPTIMAL 256-color palette for THIS content, then `paletteuse`
  renders against it with dithering. This is the difference between
  an ugly GIF and a clean one.

# Workflow

## High-quality GIF (palettegen / paletteuse two-pass)

## verify input + decide the loop length
```bash
  test -f "$1" || { echo "input file $1 not found"; exit 1; }
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"
  # GIF size ≈ frames × pixels. Keep it short (≤6s) and small (≤640w).
```

## pass 1 — build a content-optimal palette
```bash
  ffmpeg -i input.mp4 \
    -vf "fps=15,scale=480:-1:flags=lanczos,palettegen=max_colors=256" \
    -y palette.png
  # fps + scale here MUST match pass 2 — the palette is sampled from
  # the SAME pipeline. lanczos = sharper downscale than the default.
```

## pass 2 — render the GIF against that palette
```bash
  ffmpeg -i input.mp4 -i palette.png \
    -lavfi "fps=15,scale=480:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=sierra2_4a" \
    -y out.gif
  # dither hides banding. sierra2_4a = good default; bayer:bayer_scale=3
  # = smaller file with a subtle crosshatch; none = smallest but bands.
```

## one-liner (palette stays in memory, no temp file)
```bash
  ffmpeg -i input.mp4 -filter_complex \
    "fps=15,scale=480:-1:flags=lanczos,split[a][b]; \
     [a]palettegen=max_colors=256[p];[b][p]paletteuse=dither=sierra2_4a" \
    -y out.gif
  # split feeds the same frames to palettegen and paletteuse in one run.
```

## fps / scale tradeoffs (the size dials)

  | Dial         | Smaller file        | Better motion / detail   |
  |--------------|---------------------|--------------------------|
  | `fps`        | 10-12 (choppier)    | 20-25 (smoother, bigger) |
  | `scale` width| 320-400             | 640-800                  |
  | dither       | `none` / `bayer`    | `sierra2_4a` (cleaner)   |
  | `max_colors` | 64-128 (banding)    | 256 (full)               |

  GIF has no inter-frame motion compensation — every frame is
  near-independent, so doubling fps roughly doubles size. Drop fps
  before you drop resolution; 15fps reads fine for UI demos.

## WebM / VP9 (the small, modern default)

## VP9 + Opus, CRF mode (quality-targeted, much smaller than GIF)
```bash
  ffmpeg -i input.mp4 \
    -c:v libvpx-vp9 -crf 32 -b:v 0 \
    -c:a libopus -b:a 96k \
    out.webm
  # -b:v 0 is REQUIRED to put VP9 in constant-quality (CRF) mode.
  # Without it, -crf is ignored and you get a constrained-bitrate encode.
  # VP9 CRF range ~15 (high) .. 35 (web) .. 50 (low). Higher = smaller.
```

## silent autoplay loop for web (no audio, faststart-style)
```bash
  ffmpeg -i input.mp4 \
    -an -c:v libvpx-vp9 -crf 34 -b:v 0 \
    -pix_fmt yuv420p \
    loop.webm
  # -an drops audio (browsers require muted for autoplay anyway).
```

## VP9 WITH alpha/transparency (yuva420p, for compositing)
```bash
  ffmpeg -i input_with_alpha.mov \
    -c:v libvpx-vp9 -crf 30 -b:v 0 -pix_fmt yuva420p \
    -an alpha.webm
  # yuva420p preserves the alpha plane. The 'a' is the alpha channel;
  # plain yuv420p would silently flatten transparency to black.
```

## Animated WebP (GIF replacement that's still an <img>)

  Needs ffmpeg built with `--enable-libwebp`. Some minimal builds
  omit it → "Unknown encoder 'libwebp'". Check with
  `ffmpeg -encoders | grep webp`; if absent, ship a VP9 WebM (above)
  or a two-pass GIF instead.

## animated WebP loop, quality + compression tuned
```bash
  ffmpeg -i input.mp4 \
    -vf "fps=15,scale=480:-1:flags=lanczos" \
    -c:v libwebp -lossless 0 -q:v 70 -compression_level 6 \
    -loop 0 -an \
    out.webp
  # -loop 0 = infinite loop. -q:v 0..100 (higher = better). -lossless 1
  # for crisp UI/screen captures (bigger). compression_level 0..6 (6 = best/slow).
```

## Verify size + that it actually animates

## confirm frame count > 1 and report size
```bash
  for f in out.gif loop.webm out.webp; do
    [ -f "$f" ] || continue
    sz=$(du -h "$f" | cut -f1)
    nf=$(ffprobe -v error -count_frames -select_streams v:0 \
          -show_entries stream=nb_read_frames -of csv=p=0 "$f" 2>/dev/null)
    echo "$f: $sz, frames=$nf"
    [ "${nf:-0}" -gt 1 ] 2>/dev/null || echo "  ⚠ $f has ≤1 frame — not animated"
  done
```

# Common pitfalls

  1. *Single-pass GIF → banding + wrong colors.* The default generic
     palette wrecks gradients and brand colors. Always do the
     palettegen/paletteuse two-pass (or the split one-liner).

  2. *Palette pass fps/scale ≠ render pass.* The palette must be
     sampled from the SAME pipeline it's applied to. If pass 1 uses
     fps=15,scale=480 then pass 2 MUST too, or colors drift.

  3. *VP9 -crf with no `-b:v 0`.* This is THE VP9 footgun: `-crf` is
     silently ignored unless you also pass `-b:v 0` to enable
     constant-quality mode. You'll get an unexpectedly large or
     low-quality file and no error.

  4. *Huge GIF.* Almost always: too long, too high fps, or too wide.
     Trim to the loop, drop to 12-15fps, cap width ~480. A 10s 720p
     GIF can be 50MB+; the same clip as VP9 is often <1MB.

  5. *WebP loses the loop.* Forgetting `-loop 0` can yield a single-
     play (or single-frame) WebP. `-loop 0` = infinite; a positive N
     = that many plays.

  6. *Transparency flattened to black.* GIF supports only 1-bit
     (on/off) alpha; partial transparency hard-edges. For smooth
     alpha use VP9 (`yuva420p`) or WebP — and remember plain
     `yuv420p` drops alpha entirely.

  7. *Odd dimensions on VP9/WebP.* Same even-dimension rule as H.264
     for the yuv420p path — use =scale=480:-2= not `-1` if you hit
     "not divisible by 2".

# Verification checklist

  - [ ] Output animates (frame count > 1, not a frozen still)
  - [ ] GIF: no obvious banding on gradients (two-pass used)
  - [ ] File size reasonable for the surface (VP9 ≪ GIF for same clip)
  - [ ] Loop behaves (WebP `-loop 0`, WebM autoplays muted)
  - [ ] Alpha preserved if needed (yuva420p / lossless WebP)
  - [ ] Colors match source on brand assets

# See also

  - [trim](trim.md) — cut to the exact loop BEFORE exporting (biggest size lever)
  - [video-scale-crop](video-scale-crop.md) — reframe/resize before the export
  - [video-fps-speed](video-fps-speed.md) — speed-ramp or timelapse the loop first
  - [lossy-tradeoffs](lossy-tradeoffs.md) — CRF mental model (applies to VP9 too)
  - =ffmpeg -h filter=palettegen= / =-h filter=paletteuse= / =-h encoder=libvpx-vp9=
