# ffmpeg — burn subtitles into a video
0.1.0
Use when subtitles need to be permanently rendered onto a video — for platforms that don't support sidecar tracks, or to bake in styled captions for social-media uploads.

# When to use this
NETWORK: no
DESTRUCTIVE: no

  Captions need to be PIXELS in the video, not a separate
  selectable track. Common cases:

  - Social platforms (Instagram Reels, TikTok) that don't
    render sidecar subtitle tracks
  - Distribution where you can't guarantee the player has
    subtitle support
  - Stylized captions where you want full ASS / SSA control

  NOT for: shipping selectable subtitles (use `-c:s mov_text`
  to mux SRT into mp4); auto-generating subtitles (use whisper
  or another STT first, then this skill to burn).

# Workflow

## SRT (simple)

## verify inputs
```bash
  test -f input.mp4 || { echo "video missing"; exit 1; }
  test -f subs.srt  || { echo "subtitles missing"; exit 1; }
  head -5 subs.srt
```

## burn SRT using default styling
```bash
  ffmpeg -i input.mp4 -vf "subtitles=subs.srt" -c:a copy out.mp4
  # video re-encoded with subtitles overlaid; audio stream-copied
```

## SRT with custom style

## bigger font + outline for readability over busy video
```bash
  ffmpeg -i input.mp4 \
    -vf "subtitles=subs.srt:force_style='FontSize=28,OutlineColour=&H40000000,BorderStyle=3,Outline=3'" \
    -c:a copy out.mp4
```

  Common force_style fields:

  | Field            | Effect                                      |
  |------------------|---------------------------------------------|
  | FontName         | e.g. `Arial Bold`                           |
  | FontSize         | integer pt; 24-32 is good for HD            |
  | PrimaryColour    | `&Hbbggrr` (BGR hex)                        |
  | OutlineColour    | as above; with BorderStyle=3 = bg box       |
  | BorderStyle      | 1=outline, 3=opaque box                     |
  | Outline          | outline width px                            |
  | Alignment        | 1=bottom-left, 2=bottom-center, 8=top-center|

## ASS / SSA (full styling)

  ASS subtitles can be authored externally with full
  positioning, animations, karaoke effects:

## burn an ASS file
```bash
  ffmpeg -i input.mp4 -vf "ass=fancy.ass" -c:a copy out.mp4
```

## Verify

## spot-check by extracting a frame mid-video
```bash
  test -f "$1" || { echo "output missing"; exit 1; }
  # extract a frame 30s in — should show burned subtitles
  ffmpeg -y -ss 30 -i "$1" -frames:v 1 burn-check.png 2>/dev/null
  echo "✓ extracted burn-check.png — visually verify caption is present"
```

# Common pitfalls

  1. *Subtitles invisible.* Most common cause: SRT file has wrong
     encoding (Windows CP1252 vs UTF-8). Convert with
     `iconv -f cp1252 -t utf-8 subs.srt > subs.utf8.srt` and burn
     that.

  2. *Font not found.* `subtitles` filter uses libass which uses
     fontconfig. If the font in force_style isn't installed,
     fallback may be silent + ugly. Install the font system-wide
     OR specify a guaranteed-present face (e.g. `Arial`,
     `Helvetica`).

  3. *Timing off.* Most often: source video has a different
     framerate than the SRT was timed against. =-vf
     "subtitles=subs.srt:original_size=1920x1080"= sometimes fixes
     scaling, but timing requires re-timing the SRT.

  4. *Burning is destructive + irreversible.* Once burned, the
     subtitles are pixels — no way to disable or restyle. Keep
     the original mp4 + SRT around.

  5. *Quotes inside force_style.* Bash quoting on force_style
     trips a lot of users. Quote with single, escape inner with
     double, OR use the `-filter_complex_script` variant for
     long filter graphs.

# Verification checklist

  - [ ] Subtitles visible at multiple timestamps (spot-check 3+ frames)
  - [ ] Audio preserved (`ffprobe` shows audio stream still present)
  - [ ] Font rendered as expected (not falling back to ugly default)
  - [ ] No timing drift (subs land on the right words)

# See also

  - [transcode-to-h264](transcode-to-h264.md) — re-encode video for browser delivery
  - [overview](overview.md) — argument-order gotcha for filters
