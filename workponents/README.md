# workponents

The Workbooks web-component SDK — themed, framework-agnostic `<wb-*>` custom elements.
**One substrate, many domains.** Native custom elements (zero runtime dependency), so the
same element runs in the **desktop app**, **any workbook** (plain HTML, no build), and as a
**public dev-kit**. A toolkit, the `web-components` KIND (see `manifest.org`).

> Full vision, per-domain reinventions, and roadmap: [`../docs/WORKPONENTS.md`](../docs/WORKPONENTS.md).

## Use it

```html
<link rel="stylesheet" href="workponents/src/theme/tokens.css" />
<script type="module" src="workponents/src/index.js"></script>

<wb-button variant="solid" tone="brand" size="md">Save</wb-button>
```

No build step. Theme by setting `data-wb-theme="light|dark|signal"` (or your own) on an
ancestor — every element re-themes from the tokens. See `demo/index.html` for the specimen.

## How it's built (the conventions every element follows)

- **Token-only styling.** Elements style *only* from `--wb-*` CSS custom properties
  (`src/theme/tokens.css`). Custom properties inherit through the shadow boundary, so one token
  set themes all domains *and* the workbook artifacts. Per-workspace brands = a token scope.
- **Variants as reflected attributes.** `variant` / `size` / `tone` are attributes the component
  CSS targets via `:host([variant="solid"])`. Defaults are declared (`src/core/variants.js`) and
  reflected on connect, so selectors always match. A design-lint can flag off-system values.
- **`WbElement` base** (`src/core/element.js`) — shadow DOM, reactive attributes, adopted styles,
  the render seam. Register idempotently with `define(name, ctor)`.
- **Capability via the Host/Dock seam** (`src/core/host.js`) — elements reach compute through
  `this.host`, which resolves `local` / `runtime` (RCP) / `kernel`; the same element swaps
  providers per target. Capability toolkits (DuckDB, wavelet, the OQL kernel) back the views.

## Layout

```
workponents/
  manifest.org          # toolkit front-door (KIND: web-components)
  src/
    theme/tokens.css     # the design contract — the only place colors/shape/type live
    core/element.js      # WbElement base + define()
    core/variants.js     # the variant contract + design-lint
    core/host.js         # the Dock/Host capability seam
    elements/wb-*.js     # one element per file (wb-button = the reference)
    index.js             # register all + re-export
  demo/index.html        # the specimen / proof page (no build)
```

## Status

Phase 0 (scaffold + theming + variants + Host seam + `wb-button` reference). Verified: native
custom element upgrades + shadow-renders, themes via tokens across light/dark/signal, zero deps,
no build. Next: seed `video` (wrap wavelet) + `ai` (port the chat elements) + `docs` + `git`, then
the DuckDB trio (`tables`/`data-viz`/`maps`).
