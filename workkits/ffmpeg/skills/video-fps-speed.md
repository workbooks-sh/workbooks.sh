# ffmpeg — frame rate · speed · timelapse · interpolation
0.1.0
Use when you need to change a video's TEMPORAL properties — convert fps (30→24), speed it up or slow it down (slow-mo / fast-forward), build a timelapse, or interpolate to a higher fps. Covers the setpts-vs-fps distinction, keeping audio in sync, and minterpolate caveats.

# When to use this
NETWORK: no
DESTRUCTIVE: no

  The video's TIMING needs to change:

  - *convert fps* — retarget 60→30, 30→24, etc. (same real-time
    duration, different frame cadence)
  - *speed up / slow down* — change playback duration (2× fast-
    forward, 0.5× slow motion)
  - *timelapse* — collapse a long recording into a short clip
  - *frame interpolation* — synthesize in-between frames to raise
    fps smoothly (the expensive, caveat-heavy option)

  Two distinct operations people conflate:
  - *fps conversion* keeps duration the same; it drops/duplicates
    frames so the cadence matches a target rate.
  - *speed change* changes duration; the same frames are shown over
    more/less time (or frames are dropped to compress time).

  NOT for: trimming a range ([trim](trim.md)); resizing the frame
  ([video-scale-crop](video-scale-crop.md)).

# The core distinction: `fps` filter vs `-r` vs `setpts`

  | Tool          | What it does                                    |
  |---------------|-------------------------------------------------|
  | =fps=N=       | Filter: resample to N fps, same DURATION        |
  | `-r N`        | Output option: set container/output frame rate  |
  | `setpts`      | Rescale presentation timestamps → changes SPEED |
  | `atempo`      | Audio speed without pitch shift (pairs w/ setpts)|

  Rule of thumb: use the `fps` FILTER (not bare `-r`) for cadence
  changes inside a filtergraph — it's deterministic about which
  frames are kept/dropped. Use `setpts` when you want the clip to
  play faster/slower (duration changes).

# Workflow

## Convert frame rate (same duration)

## inspect the current frame rate
```bash
  test -f "$1" || { echo "input file $1 not found"; exit 1; }
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=r_frame_rate,avg_frame_rate,nb_frames -of default=nw=1 "$1"
  # r_frame_rate is a fraction, e.g. 30000/1001 = 29.97. avg may differ on VFR.
```

## retarget to 24 fps (drops/duplicates frames; duration unchanged)
```bash
  ffmpeg -i input.mp4 -vf "fps=24" \
    -c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p \
    -c:a copy -movflags +faststart out.mp4
  # audio is untouched — only the visual cadence changed, so -c:a copy is fine.
```

## normalize a variable-frame-rate (VFR) source to constant 30
```bash
  ffmpeg -i screen-recording.mp4 -vf "fps=30" -vsync cfr \
    -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p \
    -c:a copy out.mp4
  # VFR (screen/phone captures) confuses editors; fps + -vsync cfr forces CFR.
```

## Speed up / slow down (duration changes)

  `setpts` multiplies the presentation timestamps. `0.5*PTS` = half
  the time = *2× speed*. `2.0*PTS` ` double the time ` *half speed*
  (slow motion). Audio needs `atempo` to match, and `atempo` only
  accepts 0.5–2.0 per instance (chain for bigger factors).

## 2× faster (video + pitch-preserved audio)
```bash
  ffmpeg -i input.mp4 -filter_complex \
    "[0:v]setpts=0.5*PTS[v];[0:a]atempo=2.0[a]" \
    -map "[v]" -map "[a]" \
    -c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p \
    -c:a aac -b:a 128k out.mp4
  # setpts=0.5*PTS → 2× speed. atempo=2.0 → audio 2× without chipmunk pitch.
```

## 0.5× slow motion (video slowed; audio slowed to match)
```bash
  ffmpeg -i input.mp4 -filter_complex \
    "[0:v]setpts=2.0*PTS[v];[0:a]atempo=0.5[a]" \
    -map "[v]" -map "[a]" \
    -c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p \
    -c:a aac -b:a 128k out.mp4
  # Slow-mo from normal footage looks choppy (each frame held longer).
  # For SMOOTH slow-mo, interpolate first (see minterpolate below).
```

## 4× faster — chain atempo (each stage capped at 2.0)
```bash
  ffmpeg -i input.mp4 -filter_complex \
    "[0:v]setpts=0.25*PTS[v];[0:a]atempo=2.0,atempo=2.0[a]" \
    -map "[v]" -map "[a]" \
    -c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p \
    -c:a aac -b:a 128k out.mp4
  # atempo=2.0,atempo=2.0 = 4×. For 3×: atempo=1.5,atempo=2.0 etc.
```

## speed up video, DROP audio entirely (silent fast-forward)
```bash
  ffmpeg -i input.mp4 -vf "setpts=0.25*PTS" -an \
    -c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p out.mp4
  # -an avoids the atempo math when you don't need sound.
```

## Timelapse (collapse a long recording)

  Two routes. For a MILD speed-up, `setpts` is fine. For an EXTREME
  one (hours → seconds), drop frames first with `fps` so you don't
  decode-then-discard millions of frames.

## extreme timelapse — keep 1 frame/sec, then play at 30fps
```bash
  ffmpeg -i long-recording.mp4 -vf "fps=1,setpts=N/30/TB" -r 30 -an \
    -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p timelapse.mp4
  # fps=1 keeps one frame per source second; setpts=N/30/TB restamps those
  # kept frames to 30fps playback. A 1-hour source → ~2 minutes (3600/30).
```

## build a timelapse FROM an image sequence (frame-####.jpg)
```bash
  ffmpeg -framerate 24 -i "frame-%04d.jpg" \
    -c:v libx264 -crf 20 -preset medium -pix_fmt yuv420p timelapse.mp4
  # -framerate BEFORE -i sets how fast the stills play. %04d = zero-padded index.
```

## Frame interpolation (minterpolate) — smooth fps boost / slow-mo

  `minterpolate` SYNTHESIZES intermediate frames via motion
  estimation. It can turn 30→60 smoothly or make slow-mo fluid — but
  it is SLOW and produces artifacts on fast/complex motion. Treat it
  as a last resort, not a default.

## interpolate 30fps → 60fps (motion-compensated)
```bash
  ffmpeg -i input30.mp4 -vf \
    "minterpolate=fps=60:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1" \
    -c:v libx264 -crf 20 -preset slow -pix_fmt yuv420p -c:a copy out60.mp4
  # mci = motion-compensated interpolation (the good, slow mode).
  # Expect warping around fast edges, occlusions, and text overlays.
```

## smooth slow-mo: interpolate up, THEN slow with setpts
```bash
  ffmpeg -i input.mp4 -filter_complex \
    "[0:v]minterpolate=fps=120:mi_mode=mci,setpts=4*PTS[v]" \
    -map "[v]" -an \
    -c:v libx264 -crf 20 -preset slow -pix_fmt yuv420p smooth-slowmo.mp4
  # interpolate to 120fps then setpts=4*PTS for 0.25× speed with real
  # in-between frames instead of held duplicates.
```

## Verify duration + frame rate

## confirm the timing change took
```bash
  test -f "$1" || { echo "output missing"; exit 1; }
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=r_frame_rate:format=duration -of default=nw=1 "$1"
  # speed change → duration should scale; fps conversion → duration unchanged.
```

# Common pitfalls

  1. *setpts changes video but audio is left at original speed.* If
     you only `setpts` the video, audio desyncs immediately. Always
     pair with `atempo` (or `-an` to drop audio). They are separate
     filters on separate streams.

  2. *atempo's 0.5–2.0 limit.* A single `atempo` can't do 3× or
     0.25×. Chain instances: =atempo=2.0,atempo=2.0= = 4×;
     =atempo=0.5,atempo=0.5= = 0.25×.

  3. *Confusing `fps` (cadence) with `setpts` (speed).* =fps=15= on a
     30fps clip keeps the SAME duration (drops half the frames).
     =setpts=0.5*PTS= halves the DURATION (plays 2×). Pick by whether
     duration should change.

  4. *Bare `-r` for retiming inside filters.* `-r` sets the output
     rate but doesn't deterministically choose which frames survive,
     and can fight with filtergraph timestamps. Use the `fps` filter
     for cadence; reserve `-r` for the final container rate.

  5. *Slow-mo from normal footage is choppy.* =setpts=2*PTS= just
     holds each frame twice as long — no new information. For smooth
     slow-mo you must interpolate (`minterpolate`) or shoot at high
     fps originally.

  6. *minterpolate artifacts + cost.* Motion estimation warps fast
     edges, occlusions, and especially text/logos, and is often 10×+
     slower than a plain re-encode. Validate visually; don't ship it
     blind on busy footage.

  7. *VFR sources break naive fps math.* Screen/phone captures are
     often variable-frame-rate; `nb_frames` and `avg_frame_rate` lie.
     Normalize with =fps=N -vsync cfr= before any speed math.

# Verification checklist

  - [ ] fps conversion: duration unchanged, `r_frame_rate` = target
  - [ ] speed change: duration scaled by the inverse of the setpts factor
  - [ ] audio in sync (no drift; atempo applied or audio dropped)
  - [ ] timelapse: output length ≈ source_len × kept_fps / playback_fps
  - [ ] interpolation: no objectionable warping at 2-3 timestamps
  - [ ] browser target: yuv420p, plays end-to-end

# See also

  - [trim](trim.md) — cut the range before retiming
  - [video-audio-mux](video-audio-mux.md) — deeper on audio sync (-shortest, async)
  - [gif-webm-export](gif-webm-export.md) — fps as a GIF size lever
  - [lossy-tradeoffs](lossy-tradeoffs.md) — preset cost matters a lot for minterpolate
  - =ffmpeg -h filter=fps= / =-h filter=setpts= / =-h filter=minterpolate=
