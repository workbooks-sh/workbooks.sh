# icons

The universal icon library as a CLI. One value grammar — `mi:<def>` (Material Icon Theme), `lobe:<slug>` (AI/dev brand SVGs), emoji, `data:` images, initials — that an agent can search, resolve, and explain. What the agent writes is exactly what the desktop renders: the CLI and `Icon.svelte` carry the same grammar, kept in sync as a contract.

## When to reach for it

Reach for `icons` whenever an agent needs to pick an icon value to write into a workbook or spec — so it never invents an icon URL. Ask the CLI for a *value* and write that string; the desktop resolves it unchanged.

## Example

```
icons grammar                      # print the value grammar once
icons search "database"            # ranked across material defs, emoji, lobe slugs
icons for-file Cargo.toml          # the material def for a filename
icons get lobe:openai              # resolve any value → kind/source/url/fallback
```

## What it grants

- `search`, `for-file`, `for-folder`, `get`, and `grammar` verbs (all take `--json`; line mode is `value⇥kind⇥name⇥url`).
- One grammar over Material Icon Theme defs, LobeHub brand SVGs, emoji, `data:` images, and initials.
- Vendored, committed, regenerable packs (material/lobe/emoji); SVG bytes are not bundled — `get`/`search` emit stable CDN/raw URLs.

## Maturity

Experimental (v0.1.0). Builds in-sandbox via the QuickJS lane (`wb toolkit build icons`); the same file also runs under plain `node src/index.js` outside the runtime.
