# open-avatars

Many art styles, one DiceBear-like API. A zero-dependency, deterministic avatar engine for browser / Node / QuickJS-wasm: a single `avatar(pack, seed, opts)` routes by a pack's type — assembled (composed atoms), gallery (pick one whole avatar, SVG or raster), or procedural (a generator the pack ships). The same seed yields a byte-identical avatar across every style, forever.

## When to reach for it

Reach for `open-avatars` when a workbook or site needs stable, generated avatars — identicons, illustrated peeps, robots — without a network call or a paid service. Determinism is the whole point: same seed in, same avatar out, no randomness or timestamps.

## Example

```js
avatar("open-peeps", "wren", { crop: "bust" })   // assembled, CC0
avatar("boring", "user-42")                       // procedural marble+beam
avatar("pixabots", "robo-7")                       // gallery raster → <img>
```

## What it grants

- Seven styles ship: open-peeps (assembled), transhumans (gallery/svg), pixabots (gallery/raster), boring, jdenticon, minidenticons, pixitar (all procedural).
- Three crops for assembled figures (`circle` / `bust` / `full`); gallery and procedural packs ship one framing each.
- `opts` for seed, background/theming, and a per-pack monochrome stance where supported.
- Pure string→string, no DOM/Node/`fetch`; bad input degrades to a 1×1 canvas, never throws.

## Maturity

Experimental (v0.2.0). Ports keep their source library's exact hash for byte-parity. Per-pack attribution (all MIT or free-for-commercial) is in the toolkit's `LICENSES.md`.
