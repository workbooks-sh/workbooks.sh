# wavelet — transitions between sections

# When to use this
NETWORK: no
DESTRUCTIVE: no

  One composition needs to move from one beat to the next — section A
  leaves, section B arrives. Since wavelet renders ONE HTML file as a
  CSS-animation timeline, a "transition" is just overlapping
  `@keyframes` on stacked elements, timed by `animation-delay`.

  There is no `concat` verb. To sequence beats, put them in one
  composition and stagger their delays (recommended), or render
  separate clips and mux them with the host encode step afterward.

# Cross-fade between two sections in ONE composition

  Stack two full-bleed sections; fade A out and B in over the same
  window. Brand canon: keep fades subtle and short; prefer hard cuts
  between unrelated clips, fades only for soft beat hand-offs.

## A holds 0..2.5s, cross-fades to B at 2.5..3.0s, B holds to end
```bash
  cat > seq.html <<'HTML'
  <!doctype html>
  <html><head><style>
    html,body{margin:0;height:100%;overflow:hidden;font-family:sans-serif}
    .sec{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
         font-size:90px;font-weight:800;color:#fff}
    #a{background:#0b1020; animation: fadeout .5s 2.5s ease-in forwards}
    #b{background:#149157; opacity:0; animation: fadein .5s 2.5s ease-out forwards}
    @keyframes fadeout{from{opacity:1}to{opacity:0}}
    @keyframes fadein {from{opacity:0}to{opacity:1}}
  </style></head>
  <body>
    <div id="a" class="sec">First beat</div>
    <div id="b" class="sec">Second beat</div>
  </body></html>
  HTML
  wavelet render seq.html -o seq.mp4 --duration 5 --fps 30
```

# Fade to black

  A black overlay on top that fades IN over the cut window:

```
  #curtain{position:absolute;inset:0;background:#000;opacity:0;pointer-events:none;
           animation: toblack .4s 4.6s linear forwards}
  @keyframes toblack{from{opacity:0}to{opacity:1}}
```

# Cut (no transition)

  A hard cut is just B's elements appearing at a delay with no fade —
  set B hidden (`opacity:0`) and switch it on instantly via a
  zero-ish duration animation, or stagger element delays so the new
  content simply starts at the cut time.

# Verify

```bash
  head -c 8 "$1" | tail -c 4 | grep -q ftyp || { echo "render failed"; exit 1; }
  echo "✓ transition composition rendered"
```

# Gotchas

  - Keep every `animation-delay` inside `--duration`.
  - Later-in-DOM elements paint on top; order your sections so the
    arriving one can be revealed above the leaving one.

# See also

  - [text-cards](text-cards.md) — the cards you transition between
  - [render](render.md) — produce the mp4
