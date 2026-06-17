# glyphs

One API resolves any visual mark — a brand logo, a tech icon, a seeded avatar, or a social avatar — to an SVG (or an `<img>`). A tiny, zero-dependency resolver: `glyph(ref)` is sync and curated-only (offline, returns `null` on a miss); `glyphAsync(ref)` reaches the CDN for the long tail. A ref is `"<kind>:<id>"` — `brand:google`, `icon:elixir`, `avatar:open-peeps/wren`, `social:github/octocat`.

## When to reach for it

Reach for `glyphs` when a workbook or site needs to render marks without bundling a logo set or guessing CDN URLs. The sync/async split is the design: instant curated marks offline, graceful CDN fallthrough for the long tail, and an honest `null` on a total miss — never a broken-image box.

## Example

```js
glyph("brand:stripe", { size: 24 })        // sync, curated → SVG string or null
await glyphAsync("brand:vercel")           // CDN fallthrough for the long tail
glyph("icon:elixir", { color: "#5e3" })    // recolor a currentColor icon
glyph("avatar:open-peeps/wren")            // deterministic seeded avatar, local
```

## What it grants

- Four kinds in one grammar: `brand:` (full-color logos), `icon:` (currentColor tech/UI icons), `avatar:` (deterministic seeded, local via open-avatars), `social:` (real avatars as `<img>` via unavatar).
- Curated-local-first resolve order per kind, CDN (svgl / lobehub / simple-icons) for the long tail.
- `opts` for size, color, title/aria, class, and a `mono` grayscale stance.
- Runs in browser, Node, and the runtime's StarlingMonkey-wasm lane; the curated-only path works even where `fetch` is absent.

## Maturity

Experimental (v0.1.0). Brand logos and icons are trademarks, provided for nominative/identification use only — see the toolkit's `LICENSES.md`.
