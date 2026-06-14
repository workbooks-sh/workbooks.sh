# wavelet

Wavelet is Workbooks' motion-graphics renderer — Blitz + Vello + Animato + rsmpeg — and the `wavelet` CLI is its imperative editing surface: scaffold a composition, preview it in a dev server, and render to mp4. Where the `video` toolkit is the high-level "make a video" capability, `wavelet` is the lower-level editing CLI underneath it.

## When to reach for it

Reach for `wavelet` when you need direct, imperative control over a motion-graphics composition — scaffolding source, iterating in a preview loop, and rendering the final mp4, including title cards, transitions, and audio sync.

## Example

```
wavelet init --template <name>     # empty dir → composition source
wavelet preview                     # dev loop
wavelet render                      # final mp4
```

## What it grants

- Verbs: `init`, `inspect`, `lint`, `preview`, `render`, `trim`, `split`, `cut`, `concat`, `move`, `verify`.
- Skill recipes for scaffolding a composition, the preview→render loop, text cards (titles/lower-thirds/end cards), transitions, audio sync, and picking a template.

## Maturity

Experimental (v0.1.0). Requires Node 20+. Not all verbs are stable — rely on `wavelet --help` for the current surface.
