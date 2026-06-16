# ffmpeg — lossy tradeoffs (CRF / bitrate / preset)
0.1.0
Mental model for picking CRF, bitrate, preset, and codec for a re-encode — what costs what, what to escalate when output looks/sizes wrong.

# When to use this
NETWORK: no
DESTRUCTIVE: no

  Re-encode produced output that's too big OR too low quality
  for the use case, and you need to know which knob to turn.

  Or upfront: choosing settings for a re-encode and want to
  hit a target (specific size / quality / encode time) without
  guessing.

# The three axes (and what each controls)

  | Axis    | x264 knob           | Effect                                        |
  |---------|---------------------|-----------------------------------------------|
  | Quality | `-crf <N>`          | Lower N = better quality + bigger file        |
  | Bitrate | `-b:v <rate>`       | Bigger rate = bigger file; quality variable    |
  | Speed   | `-preset <name>`    | Faster preset = lower compression efficiency  |

  *Pick ONE of -crf or -b:v.* CRF aims at a quality target and
  lets bitrate float; -b:v fixes bitrate and lets quality
  float. Don't combine; behavior is confusing.

# CRF — the default mental model

  `-crf 18`  visually lossless (most viewers can't tell from source)
  `-crf 23`  default; "good" web-delivery quality
  `-crf 28`  noticeably lossy but acceptable for small-screen viewing
  `-crf 32`  visibly degraded; only for previews / thumbs

  Each +6 ≈ doubles file size. CRF 18 produces ~4× larger
  files than CRF 30 at same source.

# Preset — speed/efficiency tradeoff

  Preset trades encoder CPU time for compression efficiency:

  `ultrafast` → file ~2× larger, encode ~10× faster than `medium`
  `fast`      → small overhead, modest size hit
  `medium`    → default
  `slow`      → ~10-15% smaller, ~2× slower
  `veryslow`  → ~20% smaller, ~5× slower

  Recipe: `medium` for routine work, `slow` for keepers,
  `ultrafast` for screen-recordings or previews you'll
  re-encode anyway.

# Codec choice — h264 / hevc / av1

  | Codec | Quality/size winner             | Compatibility            |
  |-------|---------------------------------|--------------------------|
  | h264  | Baseline (≡ libx264)            | Universal (every device) |
  | hevc  | 25-50% smaller @ same quality   | Modern only; iOS/Mac/win11 |
  | av1   | Another 20% over hevc           | Newest; not in older browsers |

  Default to h264 unless you control the delivery surface.
  Use hevc for Mac/iOS-only or your own player. AV1 for
  highest compression where decode support is verified.

# Workflow: hit a target

## "File too big"

  Knob to turn first: `-crf`. +3 to current value ≈ halves
  file size; +6 ≈ quarters.

## try a quick re-encode at crf+4
```bash
  ffmpeg -i too-big.mp4 \
    -c:v libx264 -crf 27 -preset medium -pix_fmt yuv420p \
    -c:a aac -b:a 96k \
    -movflags +faststart \
    smaller.mp4
```

## "Quality too low at acceptable size"

  Switch codecs to hevc if delivery surface allows. Same CRF
  scale; ~30% smaller at same visible quality.

## hevc re-encode
```bash
  ffmpeg -i input.mp4 \
    -c:v libx265 -crf 23 -preset medium -tag:v hvc1 \
    -c:a aac -b:a 128k \
    -movflags +faststart \
    output.mp4
  # -tag:v hvc1 → plays in QuickTime / iOS Safari
```

## "Encode is way too slow"

  Two paths: faster preset (`preset fast` or `ultrafast`) or
  hardware encoder (see [hardware-acceleration](hardware-acceleration.md)).

## "Exact target size needed"

  Two-pass encode with explicit bitrate. Target bitrate ≈
  (desired_bytes × 8) / duration_seconds / 1.1 (overhead).

## two-pass for predictable size
```bash
  ffmpeg -y -i input.mp4 -c:v libx264 -b:v 2M -preset medium -pass 1 -an -f null /dev/null && \
  ffmpeg -i input.mp4 \
    -c:v libx264 -b:v 2M -preset medium -pass 2 \
    -c:a aac -b:a 128k \
    -movflags +faststart -pix_fmt yuv420p \
    output.mp4
  rm -f ffmpeg2pass-*.log*
```

# Common pitfalls

  1. *Setting both -crf and -b:v.* Behavior depends on encoder
     version — usually CRF wins, but you can't tell from output
     why bitrate spec was ignored. Pick one.

  2. *Comparing file sizes across DIFFERENT codecs at same CRF.*
     "x264 at CRF 23" ≠ "x265 at CRF 23" — the scales are
     calibrated differently. x265 typically needs +3 to +4 CRF
     to match x264's quality at same size.

  3. *Audio bitrate ignored when comparing video size.* If video
     is 90% of total, audio bitrate barely matters. If video is
     small (clip is mostly audio), bumping audio bitrate moves
     total size more than expected.

  4. *Preset on HW encoders maps differently.* NVENC's `-preset`
     p1-p7 has no relationship to x264's preset names. See
     [hardware-acceleration](hardware-acceleration.md) for the HW-specific knobs.

  5. *Visible quality ≠ ffprobe quality.* Encoders compute
     internal quality scores (PSNR / SSIM); they don't always
     match what a human sees. The only true test is "watch
     the output side-by-side with the source."

# Verification checklist

  - [ ] Output plays end-to-end
  - [ ] Output size within ±20% of expectation (CRF can vary)
  - [ ] Visually compared to source at 2-3 timestamps
  - [ ] If two-pass: `ffmpeg2pass-*.log` cleaned up

# See also

  - [transcode-to-h264](transcode-to-h264.md) — the baseline re-encode pattern
  - [hardware-acceleration](hardware-acceleration.md) — speed when CPU isn't enough
