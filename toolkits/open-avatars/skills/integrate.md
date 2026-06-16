# open-avatars — integrate

# When to use this

Read this when your task is to *plug open-avatars into a site* — a static page,
a server-rendered template, a single HTML file, a component framework, or the
runtime's wasm JS lane. The job is always the same shape: load a pack bundle,
call `avatar(bundle, seed, opts)`, drop the returned SVG string into the page.

# The two artifacts

- `dist/open-avatars.js` — the renderer. Zero dependencies. Exposes three
  functions, three ways:
  - ES module: `import { avatar, pick, register } from "./open-avatars.js"`
  - browser global: load via `<script>`, then `window.OpenAvatars.avatar(...)`
  - CommonJS: `const { avatar } ` require("./open-avatars.js")=
- `packs/<pack>/pack.bundle.json` — a *pure JSON* object (`pack.json` + the
  stripped atom SVGs). This is what `avatar()` consumes. Generate it with
  `node scripts/bundle-pack.mjs <pack>` (see `skills/packs`).

The renderer is *pure string→string*: no DOM, no Node APIs, no `fetch`. The same
file runs in a browser tag, in Node at build time, and in QuickJS-wasm. That
portability is the point — pick the delivery that fits, the renderer doesn't
change.

# The three-line minimum (browser)

```html
<div id="me" style="width:96px"></div>
<script src="open-avatars.js"></script>
<script type="application/json" id="pack">/* contents of pack.bundle.json */</script>
<script>
  var bundle = JSON.parse(document.getElementById("pack").textContent);
  document.getElementById("me").innerHTML =
    OpenAvatars.avatar(bundle, "ada@example.com");   // → a complete <svg> string
</script>
```

Fetch the bundle instead of inlining it when it lives as a file:

```html
<script>
  fetch("packs/open-peeps/pack.bundle.json").then(r => r.json()).then(bundle => {
    OpenAvatars.register(bundle);                    // set it as the default
    document.getElementById("me").innerHTML =
      OpenAvatars.avatar(null, "ada@example.com");   // null → the registered default
  });
</script>
```

The SVG string is self-contained (its own `viewBox`, `<title>`, and — for the
circle crop — a seed-unique `clipPath` id, so many avatars coexist on one page).
Size it by styling the wrapper, or pass `opts.size` for explicit `width/height`.

# Build-time prerender (no JS, no bundle shipped to the client)

Render once at build time and ship a static `<img>` or inline SVG — the renderer
runs anywhere a string transform runs.

In Node:

```bash
node -e "import('./dist/open-avatars.js').then(async m => {
  const fs = await import('node:fs');
  const bundle = JSON.parse(fs.readFileSync('packs/open-peeps/pack.bundle.json','utf8'));
  fs.writeFileSync('public/avatars/ada.svg', m.avatar(bundle, 'ada@example.com'));
})"
```

In the runtime's JS lane (QuickJS wasm) it is the *same* call — no Node globals
are touched. Pass the parsed bundle object and `avatar(bundle, seed)` is all you
need. (The bundle is plain JSON; embed it however that lane loads data.)

# Using it from a framework (Svelte / React / anything)

Do *not* reach for a component library — open-avatars ships none on purpose.
Render the *string* and inject it.

Svelte:

```svelte
<script>
  import { avatar } from "open-avatars";
  import bundle from "open-peeps/pack.bundle.json";
  export let seed;
  $: svg = avatar(bundle, seed, { crop: "circle" });
</script>
<span class="avatar">{@html svg}</span>
```

React:

```jsx
import { avatar } from "open-avatars";
import bundle from "open-peeps/pack.bundle.json";
export function Avatar({ seed, crop = "circle" }) {
  return <span dangerouslySetInnerHTML={{ __html: avatar(bundle, seed, { crop }) }} />;
}
```

The output is plain SVG with no framework dependency anywhere; the framework's
only job is to place the string.

# The API

The same call serves every pack TYPE — `avatar()` routes by `pack.type`
(assembled / gallery / procedural; see `skills/packs`). The examples above use the
assembled open-peeps pack; the contract below is the assembled one. Gallery packs
take `{ base, size, title, background }` (and raster galleries return an `<img>`,
not an `<svg>`); procedural packs pass `opts` straight to their generator and need
their `generate` function attached to the pack object. The plug-in mechanics
(inline a bundle, inject the string) are identical across all three.

- `avatar(pack, seed, opts) -> string` — a complete `<svg>` (or `<img>` for raster
  galleries).
  - `pack` : a bundle object, or `null` to use a `register()`'d default. For a
    procedural pack: `{ type:"procedural", generate }` (attach the imported fn).
  - `seed` : any string. Hashed (FNV-1a) for selection. Same seed → identical out.
  - `opts` (assembled):
    - `crop` : `'circle'` (default) | `'bust'` | `'full'`
    - `categories` : `string[]` subset to draw (default is crop-appropriate)
    - `background` : a CSS color for a backplate (default: none/transparent)
    - `size` : px for the svg's `width/height` (default: scales to its box)
    - `title` : `<title>` text for a11y (default: the seed)
  - `opts` (gallery raster): `base` — URL/path prefix for the `<img src>` (where
    you host the bitmaps); plus `size`, `title`.
  - `opts` (procedural): passed straight to the pack's `generate(seed, opts)`
    (e.g. `monochrome`, `variant`, `size` — pack-specific).
- `pick(pack, seed)` — assembled: `{ <cat>: <name> }`; gallery: the chosen id.
  Useful for debugging or showing the composition.
- `register(pack) -> void` — set a default pack so you can call `avatar(null, …)`.

# Done-when

The avatar renders, the *same seed always produces the same face*, and you wrote
no recoloring and no framework-specific styling — you leaned on the string
output. If you found yourself editing `open-avatars.js` to change a position,
stop: that is a calibration task in the pack's `pack.json` (see `skills/packs`).
