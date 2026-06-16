# workponents registry — copy-in distribution

The shadcn-style registry: instead of `npm install`-ing a black box, a consumer
**copies a themed `<work-*>` element and its transitive dependency set into
their own project**, where they own and can edit the source. Generated entirely
from `src/**` + the CEM (`custom-elements.json`) — additive tooling, never a
hand-maintained manifest.

Regenerate deterministically:

```sh
npm run registry
```

## The copy-in model

Each `registry/<tag>.json` is a self-contained recipe:

| field | meaning |
|-------|---------|
| `files` | the **transitive closure** of the element's local source — the entry element file (`registry:element`, which self-registers the tag via `define()`) plus every `../core/*`, `../../data/*`, `../../validate/*`, and tier file it imports (`registry:lib`). Lean: only this tag's deps, not its sibling elements. Each carries `content` + a `target` (where it lands in the consumer's tree). |
| `dependencies` | install-time npm packages the file set imports as bare specifiers (e.g. `lit`). |
| `peerDependencies` | **optional** CDN engines the element lazy-`import()`s at runtime (Observable Plot, MapLibre, CodeMirror, MiniSearch) — only needed to light up the heavy tier. |
| `registryDependencies` | other registry items this one pulls — always `theme`; `data` for the data surfaces; `validate` for forms. |
| `cssVars` / `tokens` | the `--work-*` design-contract slice the element consumes. |
| `attributes` / `events` / `domain` | from the CEM. |

To install a component, a consumer (or a CLI/agent) resolves it recursively:

1. Copy every file in `files` to its `target`.
2. Copy each `registryDependencies` item's files (`theme` → `tokens.css` + the
   theme-contract + `applyTheme`/`registerTheme`; `data`/`validate` as needed).
3. `npm install` the union of `dependencies`; optionally the
   `peerDependencies` to enable the heavy tier.
4. Import the element file (registers the tag) and drop `<work-model …>` in markup.

Every component pulls **theme**, so a copy-in always lands with the design
contract — no element ships an orphaned token.

## Components (52 tags · 20 domains)

- **3d** —  (`work-model`, `work-model-source`)
- **ai** — Conversational surfaces — thread, message, generative block, composer. (`work-composer`, `work-gen-block`, `work-message`, `work-thread`)
- **auth** — Identity & access — sign-in, the current user, capability gates. (`work-auth`, `work-gate`, `work-user`)
- **code** — Code surfaces — a themed editor and a sandboxed REPL. (`work-editor`, `work-repl`)
- **core** — The base element + variant contract + the reference work-button. (`work-button`)
- **data** —  (`work-query`)
- **data-viz** — A chart is a live view over a query — chart, spark, metric. (`work-chart`, `work-metric`, `work-spark`)
- **docs** — Prose & document structure — doc, doc-cell, outline. (`work-doc`, `work-doc-cell`, `work-doc-import`, `work-doc-outline`)
- **files** — File surfaces — a drive, a file card, a dropzone. (`work-drive`, `work-dropzone`, `work-file`)
- **flow** — Agentic structure — flow (sequenced steps + build edges) and loop (cron jobs). (`work-flow`, `work-loop`)
- **forms** — Schema-driven forms — form, field, field-group (over src/validate). (`work-field`, `work-field-group`, `work-form`)
- **git** — Version surfaces — diff, history graph, restore, undo. (`work-diff`, `work-history-graph`, `work-restore`, `work-undo`)
- **live** — Realtime presence — room, presence, live value. (`work-live-value`, `work-presence`, `work-room`)
- **maps** — Geospatial — a map as a view over a spatial query. (`work-map`)
- **pm** — Project management — task, board, sprint, milestone. (`work-board`, `work-milestone`, `work-sprint`, `work-task`)
- **presentation** — Slide decks — deck and slide. (`work-deck`, `work-slide`)
- **records** — Structured records — record, record-list, field-value. (`work-field-value`, `work-record`, `work-record-list`)
- **search** — Search & command — search box, command palette, command item. (`work-command`, `work-command-item`, `work-search`)
- **tables** — Tabular data over the shared engine — table and column. (`work-column`, `work-table`)
- **video** — Video surfaces — video and video-source. (`work-video`, `work-video-source`)

Library items: `data`, `validate` · style item: `theme`.

## Editor support

`registry/html-custom-data.json` is a VS Code `html.customData` file — point
`"html.customData": ["./workponents/registry/html-custom-data.json"]` at it for
`<work-*>` tag + attribute autocomplete.

## Relationship to the toolkit `#+REQUIRES` graph

This registry is the **artifact-side mirror** of the runtime's toolkit
dependency graph. A component toolkit declares its dependencies with
`#+REQUIRES`; the runtime computes a **transitive closure at subscription time**
(dedup + cycle-detect, a DAG) and flattens it into the agent's prompt index.

The registry computes the **same closure statically** — by following each
element's `import` graph — and materializes it as copy-in `files` +
`registryDependencies`. One dependency idea, two distribution surfaces:

| | toolkit graph (runtime) | registry (artifact) |
|---|---|---|
| edge | `#+REQUIRES` | `import "…"` / `registryDependencies` |
| closure | computed at subscription time | computed at `npm run registry` |
| result | flattened prompt index | copied-in source tree |
| dedup / cycle | yes (DAG) | yes (visited set) |

A consumer subscribing to a component toolkit and a consumer copying it in get
the **same transitive dependency set** — resolved by the same idea, delivered
through the surface that fits where the component runs.
