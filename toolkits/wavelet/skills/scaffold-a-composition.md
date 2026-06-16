# wavelet — scaffold a composition

# When to use this
NETWORK: no
DESTRUCTIVE: no

  Empty directory; you need a starting-point composition to iterate
  on. There is no `init` command — a wavelet composition is just an
  HTML file you write. This skill gives you a known-good skeleton.

# The composition skeleton

  Full-bleed dark canvas, an absolutely-positioned headline that
  slides in, and a progress bar that grows for the clip's length —
  all pure CSS `@keyframes`. Save as `clip.html`:

## write a starter composition
```bash
  cat > clip.html <<'HTML'
  <!doctype html>
  <html>
    <head>
      <style>
        html, body { margin:0; padding:0; width:100%; height:100%;
                     background:#0b1020; overflow:hidden; font-family:sans-serif; }
        h1 { position:absolute; left:80px; top:260px; margin:0;
             font-size:96px; font-weight:800; letter-spacing:-0.03em; color:#fff;
             animation: slidein 1s ease-out forwards; }
        p  { position:absolute; left:84px; top:380px; margin:0;
             font-size:34px; color:#3fe081;
             animation: slidein 1s 0.25s ease-out both; }
        @keyframes slidein {
          from { opacity:0; transform:translateX(60px); }
          to   { opacity:1; transform:translateX(0); }
        }
        #bar { position:absolute; left:0; bottom:0; height:18px;
               background:linear-gradient(90deg,#149157,#3fe081);
               animation: grow 4s linear forwards; }
        @keyframes grow { from { width:0; } to { width:1280px; } }
      </style>
    </head>
    <body>
      <h1>Wavelet</h1>
      <p>frames assembled in the nexus</p>
      <div id="bar"></div>
    </body>
  </html>
  HTML
```

## confirm the file exists and is HTML
```bash
  test -f "$1" || { echo "$1 missing"; exit 1; }
  grep -q '<html' "$1" || { echo "$1 is not an HTML composition"; exit 1; }
  echo "✓ composition ready — render it with: wavelet render $1 -o out.mp4"
```

# Adding image assets

  Reference images by a path relative to the composition file; keep
  them in a sibling directory (conventionally `assets/`). The renderer
  resolves relative URLs against the composition's directory.

```
  <img id="logo" src="assets/logo.png" />
```

  The whole composition directory is staged into the sandbox at render
  time, so the relative path resolves exactly as written.

# Gotchas

  - Pure CSS only — no `<script>`, no JS animation libraries. Drive
    every motion with `@keyframes`.
  - The progress bar's `to { width: 1280px }` assumes a 1280-wide
    canvas; use `100%` or match it to `--w` if you change the size.
  - Fonts: use a web-safe family (`sans-serif`, `serif`, `monospace`).
    Remote font fetching is not part of the in-sandbox render lane.

# See also

  - [render](render.md) — turn this file into an mp4
  - [text-cards](text-cards.md) — title / lower-third / end-card patterns
