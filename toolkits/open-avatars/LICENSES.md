# open-avatars — licenses & attribution

The renderer (`dist/open-avatars.js`, `scripts/bundle-pack.mjs`) is original work
in this repo. Each **pack** carries its own upstream license and attribution.
Honest summary below; every pack's `pack.json` `credit` field repeats it inline.

## Packs

| Pack            | Type               | Source                                                      | Author                  | License |
|-----------------|--------------------|-------------------------------------------------------------|-------------------------|---------|
| `open-peeps`    | assembled          | https://openpeeps.com                                       | Pablo Stanley           | CC0-1.0 (art: free for commercial use) |
| `transhumans`   | gallery · svg      | https://www.transhuman.club / https://blush.design          | Pablo Stanley           | Free for commercial use |
| `pixabots`      | gallery · raster   | see `packs/pixabots/LICENSE.txt` + `SOURCE.md`              | (pixabots pack)         | See `packs/pixabots/LICENSE.txt` |
| `boring`        | procedural         | https://github.com/boringdesigners/boring-avatars           | Boring Designers        | MIT |
| `jdenticon`     | procedural         | https://github.com/dmester/jdenticon                        | Daniel Mester Pirttijärvi | MIT |
| `minidenticons` | procedural         | https://github.com/laurentpayot/minidenticons               | Laurent Payot           | MIT |
| `pixitar`       | procedural         | https://github.com/ptcodes/pixitar                          | ptcodes                 | MIT |

### Notes on art / authorship

- **open-peeps** and **transhumans** illustrations are both by **Pablo Stanley**
  and are **free for commercial use** (open-peeps is published CC0). The
  open-peeps atoms here were re-cut to monochrome; transhumans figures keep their
  original full color.
- **avataaars** and the **DiceBear** styles are **NOT bundled here**. DiceBear's
  styles are licensed **per style** (many are CC0 / CC-BY, some are not) and must
  be sourced individually from their authors — do not assume a blanket license.
  See https://www.dicebear.com/licenses/. avataaars (also Pablo Stanley) would be
  an assembled pack if/when its atoms are sourced (see `skills/packs.org` →
  "Future packs").

### Procedural-port fidelity

- **boring-avatars** — `marble` and `beam` variants ported verbatim from the
  upstream React components + utilities (MIT). Output matches the originals'
  geometry/colors; rendered as plain SVG strings instead of JSX.
- **jdenticon** — the SHA1 hash, color theme, shape table, transform, graphics,
  and SVG-path emitter are ported verbatim (MIT). Verified **byte-identical**
  `d=` path strings against the published `jdenticon` npm package for matched
  seeds/sizes.
- **minidenticons** — ported verbatim (MIT), including the library's own
  `simpleHash` (kept exact so a given username yields the same identicon as the
  original). Verified **identical** rects + hue against the published
  `minidenticons` npm package.
- **pixitar** — **DEVIATION (documented honestly).** The upstream `ptcodes/pixitar`
  is a Ruby gem that composes a PNG from random asset image files (`Array#sample`,
  non-deterministic, no shipped algorithmic generator). It cannot be ported as a
  pure deterministic seed→SVG function. This pack keeps pixitar's *intent* —
  blocky pixel-art avatars on a grid — as a deterministic, zero-dep generator
  (seeded, vertically-mirrored pixel grid of scaled rects). See the header of
  `packs/pixitar/generate.js`.

## Renderer

`dist/open-avatars.js` and the build scripts are part of the Workbooks toolkits
and contain no third-party code beyond the per-pack procedural ports above (each
of which lives in its own `packs/<name>/generate.js` with an attribution header).
