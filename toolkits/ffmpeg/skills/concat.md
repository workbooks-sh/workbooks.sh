# ffmpeg — concatenate multiple videos into one
0.1.0
Use when you have multiple video files (clips, episodes, splits) and need a single output. The right concat method depends on whether the inputs share codec / dimensions / framerate.

# When to use this
NETWORK: no
DESTRUCTIVE: no

  Two-or-more video files → one output. Pick the method by
  whether the inputs are codec-compatible:

  | Inputs                               | Method                        |
  |--------------------------------------|-------------------------------|
  | Same codec, dims, fps, audio params  | `concat demuxer` (stream-copy) |
  | Different codecs OR dims OR fps      | `concat filter` (re-encode)    |
  | Stream copy + intermediate retiming  | `-fflags +igndts`               |

  Inputs that came from the SAME source (a video split by
  trim) usually qualify for the fast path. Inputs from
  different sources usually need the slow path.

# Workflow

## Fast path — concat demuxer (stream-copy)

## 1. confirm inputs are codec-compatible
```bash
  for f in clip1.mp4 clip2.mp4 clip3.mp4; do
    ffprobe -v error -select_streams v:0 \
      -show_entries stream=codec_name,width,height,r_frame_rate -of csv "$f"
  done
  # if any row differs, fast path won't work — use the slow path
```

## 2. write the concat list file
```bash
  cat > concat.txt <<EOF
  file 'clip1.mp4'
  file 'clip2.mp4'
  file 'clip3.mp4'
  EOF
```

## 3. concat without re-encoding (very fast)
```bash
  ffmpeg -f concat -safe 0 -i concat.txt -c copy out.mp4
```

  Single-quote the file names in concat.txt (escape internal
  quotes if needed). `-safe 0` allows relative paths.

## Slow path — concat filter (re-encode)

  Use when codecs / dims / fps differ. The filter re-decodes
  + re-encodes everything to one consistent stream.

## concat 3 disparate clips, re-encoding to a uniform output
```bash
  ffmpeg \
    -i clip1.mp4 -i clip2.mp4 -i clip3.mov \
    -filter_complex "[0:v][0:a][1:v][1:a][2:v][2:a]concat=n=3:v=1:a=1[v][a]" \
    -map "[v]" -map "[a]" \
    -c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p \
    -c:a aac -b:a 128k \
    -movflags +faststart \
    out.mp4
  # n=3 = number of inputs; v=1 audio=1 = expect video + audio per input
```

## Confirm output

## total duration should ≈ sum of input durations
```bash
  test -f "$1" || { echo "output missing"; exit 1; }
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"
```

# Common pitfalls

  1. *Concat demuxer fails silently for incompatible inputs.* Output
     plays the first clip then garbles. ffmpeg may or may not
     warn — always pre-flight with the ffprobe loop above.

  2. *Audio gaps between clips on concat demuxer.* If the audio
     tracks have different sample rates or channel layouts, even
     "same codec" gets distorted. Re-encode the audio with
     `-c:a aac` even when video is stream-copied.

  3. *Concat filter without -map.* Without `-map "[v]" -map "[a]"`,
     ffmpeg picks default streams which usually means audio from
     just one input. Always explicit-map after concat filter.

  4. *Relative paths in concat.txt + chdir.* The paths in concat.txt
     are relative to the WORKING DIRECTORY, not the file's location.
     Use absolute paths to avoid surprises.

  5. *Concat filter with input that has NO audio.* Filter spec
     `[0:v][0:a]` fails if input 0 has no audio. Either supply
     a silent audio track via `-f lavfi -i anullsrc` or use
     =a=0= in the filter (=concat=n=3:v=1:a=0=).

# Verification checklist

  - [ ] Output duration ≈ sum of input durations (±0.1s tolerance)
  - [ ] No A/V desync at clip boundaries
  - [ ] All clips visible (scrub through; first + last + boundaries)
  - [ ] If slow path used: re-encoded to browser-safe yuv420p

# See also

  - [trim](trim.md) — produce the inputs to concat
  - [transcode-to-h264](transcode-to-h264.md) — normalize inputs before concat-demuxer
