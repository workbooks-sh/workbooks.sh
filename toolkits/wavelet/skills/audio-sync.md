# wavelet — add a soundtrack (mux an mp3)

# When to use this
NETWORK: no
DESTRUCTIVE: no

  The rendered clip needs sound — a music bed, a voiceover, an sfx
  track. Pass `--audio <file.mp3>` to `wavelet render`; the host
  encode broker muxes it as an AAC track alongside the video.

  Wavelet does not generate or analyze audio — there is no beat
  detection or auto-sync. You time visuals to the audio by HAND:
  pick the beat times, and set your CSS `animation-delay` to match.

# Mux an mp3 onto the clip

## render with a soundtrack (video trims to the shorter stream)
```bash
  wavelet render clip.html -o out.mp4 --duration 6 --fps 30 --audio bed.mp3
```

  The clip length is `min(--duration, audio length)` — the encoder
  uses `-shortest`, so a long bed under a 6s clip yields a 6s mp4, and
  a 4s bed under a 6s clip yields ~4s.

# Hand-timing visuals to audio

  Decide the beat times (e.g. hits at 0.5s, 1.0s, 1.5s) and drive each
  visual with an `animation-delay` equal to that beat:

```
  .hit1{animation: pop .2s 0.5s ease-out both}
  .hit2{animation: pop .2s 1.0s ease-out both}
  .hit3{animation: pop .2s 1.5s ease-out both}
  @keyframes pop{from{transform:scale(.6);opacity:0}to{transform:scale(1);opacity:1}}
```

# Verify the audio track landed

## confirm the mp4 has an AAC audio stream
```bash
  ffprobe -v error -select_streams a:0 -show_entries stream=codec_name \
    -of default=nw=1:nk=1 "$1" | grep -q aac \
    && echo "✓ audio muxed (aac)" || { echo "no audio stream"; exit 1; }
```

# Gotchas

  - Only mp3 input is wired for the `--audio` flag.
  - The audio file is staged into the sandbox scratch by the renderer,
    so a relative or absolute path both work as long as it is readable.
  - There is no automatic beat sync; if visuals drift from the music,
    nudge the `animation-delay` values.

# See also

  - [render](render.md) — the render command + flags
  - [text-cards](text-cards.md) — time text to the beats
