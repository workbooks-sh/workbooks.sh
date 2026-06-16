# glyphs — licenses & attribution

The resolver (`dist/glyphs.js`, `dist/glyphs.css`, `scripts/build-curated.mjs`)
is original work in this repo. glyphs **resolves** marks from external sources;
it bundles a small **curated set** (inlined into `packs/*.json`) and otherwise
fetches at runtime. Each source carries its own license — and, separately, the
**marks themselves are trademarks of their owners**. See the trademark note below.

## Sources

| Source         | What                                  | Code license | Mark status |
|----------------|---------------------------------------|--------------|-------------|
| [svgl](https://svgl.app)            | full-color brand logos (663+)  | MIT (the repo/API)     | logos are **trademarks** of their owners |
| [simple-icons](https://simpleicons.org) | currentColor brand/tech icons | CC0-1.0 (the icon files) | icons are **trademarks** of their owners |
| [lobehub/lobe-icons](https://github.com/lobehub/lobe-icons) | AI/LLM brand icons (currentColor) | MIT (the repo) | brand marks are **trademarks** of their owners |
| [unavatar](https://unavatar.io)     | social-avatar lookup service   | MIT (the service)      | returns third-party user images as-is |
| `open-avatars` (this repo's toolkit) | seeded, deterministic avatars  | per-pack (MIT / CC0 / free-commercial) | see `toolkits/open-avatars/LICENSES.md` |

## What is committed vs fetched

- **Committed (curated):** `packs/curated-brands.json`, `packs/curated-icons.json`
  inline a small set of SVGs so the common marks are instant + offline.
  `packs/svgl-index.json` is svgl's name→route map (no art, just URLs).
  `packs/open-avatars/` vendors this repo's open-avatars renderer + the
  open-peeps bundle so `avatar:` works with no network.
- **Fetched at runtime (long tail):** any `brand:`/`icon:` not in the curated
  packs resolves through `glyphAsync()` against svgl / lobehub / simple-icons.
  `social:` is always a live `unavatar.io` request (the browser loads the `<img>`).

Refresh the committed curated JSON with `node scripts/build-curated.mjs` (pulls
from the live sources above).

## Trademark note — nominative / identification use only

The brand logos and icons resolved by glyphs are the **trademarks of their
respective owners**. They are provided for **nominative / identification use**
only — to refer to a company, product, or technology (e.g. "runs on Elixir",
"compared to OpenAI"). Using a mark **does not imply endorsement, affiliation,
or sponsorship** by the trademark owner. Respect each owner's brand guidelines
(several svgl rows carry a `brandUrl` linking the owner's usage policy). Do not
alter a logo in a way that misrepresents the brand. The `open-avatars` and
`unavatar`-served images carry their own per-source terms above.

## Resolver

`dist/glyphs.js`, `dist/glyphs.css`, and the build script are part of the
Workbooks toolkits and contain no third-party code. The vendored
`packs/open-avatars/open-avatars.js` is this repo's own toolkit (copied for
zero-network `avatar:` resolution) — see `toolkits/open-avatars/`.
