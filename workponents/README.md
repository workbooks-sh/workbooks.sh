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

**Phase 0** — scaffold + theming + variants + Host seam + `wb-button` reference. Verified: native
custom-element upgrades + shadow-render, themes via tokens across light/dark/signal, zero deps, no build.

**Phase 1 seeds (done)** — four domains, 14 elements, all following the Phase-0 conventions, themed
across light/dark/signal, registering from one import with zero console errors:
- `ai` — `wb-thread` / `wb-message` / `wb-gen-block` / `wb-composer` (conversation-as-source).
- `docs` — `wb-doc` / `wb-doc-cell` / `wb-doc-outline` (the doc IS its org/markdown source; live cells).
- `git` — `wb-diff` (semantic org-block diff + line fallback, in-JS) / `wb-history-graph` / `wb-restore` / `wb-undo`.
- `video` — `wb-video` / `wb-video-source` (themed wrappers over the shipped wavelet player).

**Phase 2 — the DuckDB trio (done)** — one in-WASM engine (`src/data/`: DuckDB-wasm / runtime tier /
in-JS memory floor, behind the Host seam), three surfaces binding the `{columns, rows[][], types}`
contract; all aggregation/spatial work runs as SQL in the engine, not JS:
- `tables` — `wb-table` (virtualized grid = a view over a query) / `wb-column`.
- `data-viz` — `wb-chart` (bar/line/area/scatter/pie, zero-dep SVG) / `wb-spark` / `wb-metric`.
- `maps` — `wb-map` (points/heat/choropleth; zero-dep themed projection, Host tiles when configured).

**Phase 3 — records & identity (done)** — closes the core SDK at nine domains / 31 elements:
- `forms` — `src/validate/` (shared rule contract → `{valid, errors:[{path,rule,message}]}`, sync floor + Host `/validate`) + `wb-form`/`wb-field`/`wb-field-group` (the form IS its schema).
- `records` — `wb-record`/`wb-record-list`/`wb-field-value` (entity views as queries over the shared engine; typed values; Host write).
- `search` — `wb-search` (search IS a query) + `wb-command` (⌘K; in-WASM fuzzy over commands + live data).
- `auth` — `wb-auth`/`wb-user`/`wb-gate` over a provider-agnostic identity seam on `this.host`.

**Adoption pass (in progress)** — per the [build posture](../docs/WORKPONENTS.md): the zero-dep render is the
*floor*, not a refusal. Re-base `WbElement` onto **Lit**, add **Shoelace/Web Awesome** primitives, wire
best-in-class engines (Plot/uPlot, MapLibre+PMTiles, CodeMirror/ProseMirror, MiniSearch, Standard Schema)
as the powered tier behind the same floor→wasm→Host seam, retrofit **ElementInternals/FACE** for `forms`,
and emit a **Custom Elements Manifest** + the shadcn-style copy-in registry.

**Then** — Phase 4: `presentation` / `live` / `code` / `files`, then the wrap domains.
