# Design canon — tokens + glyphs wiring

Never ship component-library defaults. The look is specific.

## Color

| Token | Dark | Light | Rule |
|---|---|---|---|
| primary "live" green | `#3fe081` | `#149157` | pair with **INK text, not white** |
| blue | — | — | **one tint only**, never a second accent |

INK (foreground text) sits on the green, not white-on-green. White-on-green is a
brand violation.

## Type

- **Geist** + **Geist Mono** only. No other families.
- Titles: serif + Geist, **size-matched**. **No mono in titles.**

## Texture

- ASCII shader + grid textures are part of the identity.
- Never reach for a UI kit's default surface/shadow/radius set.

## Marks — always via the glyphs resolver

Never hand-roll inline brand/agent SVG. Resolve through `toolkits/glyphs`.

### Wiring (do once)

**Vite alias** (path relative to your workbook's `vite.config.js`):

```js
resolve: {
  alias: { $glyphs: path.resolve(__dirname, 'toolkits/glyphs/dist/glyphs.js') },
}
```

**Configure once** at app init, importing the packs:

```js
import { configure } from '$glyphs';
import brands    from 'toolkits/glyphs/packs/curated-brands.json';
import icons     from 'toolkits/glyphs/packs/curated-icons.json';
import svglIndex from 'toolkits/glyphs/packs/svgl-index.json';
configure({ brands, icons, svglIndex });
```

### Resolving a mark

- `glyph("brand:anthropic")` — synchronous, curated packs, no network.
- `glyphAsync("brand:claude ai")` — long-tail via the svgl index (async fetch).
- A **miss returns `null`** → render nothing, never a broken-image box. Always
  provide a sync fallback for an async mark where it matters.

Marks default to `1em` so they drop inline and scale with surrounding text.
Inject the resolved SVG via your framework's HTML sink (e.g. `{@html}`).
