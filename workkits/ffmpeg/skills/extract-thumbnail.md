# ffmpeg — extract a thumbnail (single still frame)

# When to use this
NETWORK: no
DESTRUCTIVE: no

  Need a single still frame from a video at time T as a
  `.jpg` / `.png` / `.webp`. Common cases: video preview
  poster, list-view thumbnails, quick visual inspection.

# Workflow

## 1. verify input exists + show its duration
```bash
  test -f "$1" || { echo "input file $1 not found"; exit 1; }
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"
```

## 2. extract a single frame at 2s
```bash
  ffmpeg -ss 2 -i input.mp4 -frames:v 1 -q:v 2 thumbnail.jpg
  # -ss BEFORE -i = fast seek (keyframe-precise)
  # -frames:v 1   = output exactly one frame
  # -q:v 2        = JPEG quality (2-31, lower = better)
```

## 3. with explicit resize (e.g. 320x180)
```bash
  ffmpeg -ss 2 -i input.mp4 -frames:v 1 -vf scale=320:180 thumbnail.jpg
```

## 4. webp for smaller size at comparable quality
```bash
  ffmpeg -ss 2 -i input.mp4 -frames:v 1 -q:v 80 thumbnail.webp
```

## confirm output is a real image
```bash
  test -f "$1" || { echo "output $1 missing"; exit 1; }
  file "$1" | grep -qE "JPEG|PNG|WebP" || { echo "$1 not a recognized image"; exit 1; }
  echo "✓ wrote $(file "$1")"
```

# Gotchas

  - `-ss` BEFORE `-i` is fast seek (uses keyframes; may land a
    few frames off). `-ss` AFTER `-i` is precise but processes
    every frame up to T — very slow on long videos. For
    thumbnails, fast seek is fine.
  - If you get a black frame, the video might start with
    black bars. Try `-ss 5` or seek further in.
  - For multiple thumbnails at intervals (e.g. one every 10s),
    use =-vf fps=1/10= with multiple output frames instead of
    looping the command.

# See also

  - =ffprobe -v error -show_entries stream=width,height -of csv "$1"=
    to learn dimensions before resizing
  - [transcode-to-h264](transcode-to-h264.md) for full video re-encode
