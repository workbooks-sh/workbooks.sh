# The Workbook Composition Model

> The **declarative composition layer** over the already-built bundle compiler.
> Read `docs/WORKBOOK-BUNDLE.md` first — that is the canonical, byte-exact,
> security-hardened `bundle`/`unbundle` compiler (`Workbooks.Bundle`, `wb bundle`/
> `wb unbundle`). This document does **not** re-derive any of it. It specifies a
> thin layer: expressing a workbook's structure as **typed config-island custom
> elements** so composition is legible *as HTML/DOM* and authorable by hand or by a
> one-shot model — while every node still rides the existing tangle → compile → pack
> → embed lifecycle and inherits its losslessness + security floors verbatim.

## Thesis: web-component-first STRUCTURE, org-as-CONTENT

This is a layering, **not a 50/50 split** and **not org-vs-components**. One is the
container; the other is a content-type inside it.

| Layer | Owner | Rationale |
|---|---|---|
| Structure, hierarchy, composition, references, config, wiring, UI (apps, containers, agents, toolkits, data bindings, workflow *declaration*) | **Web components** | Typed/attributed/nested referencing nodes + CEM schema + heavy training-data familiarity + machine-validatable. The layer that eclipses org. |
| Narrative prose + literate code (code woven into explanation) | **Org**, inside `<work-org>`/`<work-doc>` nodes | Best literate-document format; HTML prose is worse; don't reinvent literate programming in HTML. |
| Plain source (`.rs`/`.svelte`/`.js`) | `src=`-referenced files in the bundle | Most code isn't literate; a file ref + the existing compile lane beats tangling. |

Components are the skeleton; **org is the body text of document/literate nodes**. Org
is no longer the top-level organizer — it's a vital *leaf* content format. The mix is
set by the workbook's *nature* (app/container → almost all components, org sparse;
report/notebook/literate-toolkit → `<work-org>` dominates), never chosen per project.
The layering is always the same.

### Composing org inside HTML — the rule

Raw org text contains `<` (e.g. `if (x < 3)`, literal HTML) → the HTML parser mis-reads
it as tags. So:

- **Preferred:** `<work-org src="./report.org">` — org as a bundle file. No escaping;
  `[[links]]`/references resolve against sibling node ids.
- **Inline-only-when-tiny:** a `<script type="text/org">…</script>` raw-text child
  (script content is not HTML-parsed — the `<template>` trick).
- **Never:** raw org as direct element children.

Direction is **components-outer, org-inner**. (Org's `#+begin_export html` embeds a
component as an opaque blob — fine for an embed, wrong as the primary structure.)

### Tangle / untangle — keep, but demote

Literate programming stays valuable, so don't remove tangle and don't move it to
components. In this model most code lives as `src=` files (no tangle); **tangle becomes
one residence among {inline element, src file, packed entry, tangled-from-org}, scoped
to literate-org nodes only** — a posture change, not a rewrite (the bundle compiler
already does both).

### Workflows — declaration → components, engine → host

A workflow *declaration* is structure + references + gates (the component sweet spot,
schema-backed): migrate it to a `<work-workflow>`/`<work-step>` shape. Its *control
flow* is code and stays in the engine — declarative DOM is bad at loops/conditionals
(the same reason the Workflow tool is a script, not config).

### Why this is the bet, not a coin flip

1. **Training data** — models know HTML/custom-elements; org is rare. Improves one-shot
   authorability directly.
2. **Schema** — the CEM makes structure validatable/completable; org structure isn't.
3. **The runtime is never rewritten** — the island reader (P0) is a **bijection**:
   `<work-agent>` ⟷ agent-def.org, `<work-toolkit>` ⟷ manifest.org, `<work-org>` ⟷
   `.org` file. The hardened runtime keeps eating org/trees; the authoring front-door
   becomes components; the layer translates. This is an **authoring-surface migration,
   not a runtime amputation.**

## The problem this fixes

Authoring kept treating "one HTML file" vs. "a tree of files" as a **style choice
made per prompt**, so agents waffled. The fix is to remove the choice: single-file
and multi-file are not two formats — they are **two serializations of one typed
module graph**, and moving between them is a deterministic compiler pass, never a
judgment call.

- **Bundled** (`.html`) = every node inlined / packed; polyglot sources compiled to
  artifacts and embedded. The distributable. *An output, never an authoring decision.*
- **Exploded** (working tree) = nodes in their own files; references are paths. The
  editable form, and a **context-management tool** (work one node-file at a time when
  the whole bundle won't fit a context window; re-bundle to ship).

`wb bundle` ⟷ `wb unbundle` already move between them losslessly. This layer adds a
**third, legible residence** for a node — an inline DOM element — and the mapping
between all three.

## Typed config islands

A workbook's structure is a graph of typed nodes, each a custom element. Two species:

- **Live UI elements** — `<work-table>`, `<work-chart>`, `<work-doc>` … : run in a
  browser (shadow DOM, render). The workponents SDK.
- **Inert config islands** — `<work-agent>`, `<work-toolkit>`, `<work-org>`,
  `<work-vfs>` : render nothing; carry declarative content a *reader* parses. Idiom:
  `<script type="application/json">`, `<template>`, `<picture><source>` — and our own
  `wb-bundle` block. They never "run" headlessly; the host reads them as a DSL, the
  same way it reads the `wb-bundle` / `workbook-spec` markers today.

| Island          | Carries                                   | Maps to (existing)                         |
|-----------------|-------------------------------------------|--------------------------------------------|
| `<work-org>`    | org/markdown source (incl. `:component:`) | an `.org` file in the tree; tangle source  |
| `<work-agent>`  | agent def (`** System prompt` + meta)     | an agent-def `.org` (AgentDef contract)    |
| `<work-toolkit>`| toolkit manifest + `#+REQUIRES` edges     | a toolkit dir + `manifest.org`             |
| `<work-vfs>`    | SQLite VFS / binary assets                | the embedded `wb-bundle` zip (or nexus ref)|

The islands are not a new store — they are a **legible surface** over the tree the
bundle compiler already packs. `<work-org>` is essentially `<work-doc>` with its
source addressable; `<work-vfs>` is a typed handle on the `wb-bundle` payload.

## Composition = DOM nesting = the existing DAG

```html
<work-agent id="analyst" model="…">
  <work-system>You are an analyst…</work-system>
  <work-toolkit src="./toolkits/crm.toolkit.html">      <!-- depends on the CRM toolkit -->
    <work-toolkit src="./toolkits/browser.toolkit.html"/> <!-- …which depends on browser -->
  </work-toolkit>
  <work-toolkit src="workponents"/>                       <!-- and the UI lib -->
</work-agent>
```

Containment edges = the `#+REQUIRES` toolkit DAG the host **already resolves
transitively** (`toolkits.ex` `closure`/`parse_requires`). Exploded, containment
becomes `src` paths across files; bundled, it inlines and recurses. The host resolves
the identical closure either way. Toolkit-in-toolkit-in-agent falls out for free.

## The one rule: a node has three equivalent residences

```
  inline element         external file            zip entry
  <work-toolkit          <work-toolkit            toolkits/crm/…
    id="crm">…</…>   ⟷    id="crm"             ⟷   (in the wb-bundle
                          src="./crm…"/>            payload)
```

All three are the same node. The compiler swaps between them mechanically — exactly
how the web inlines/externalizes `<script src>` ⟷ `<script>`, `<link>` ⟷ `<style>`,
`<img src>` ⟷ `data:`. **inline ⟷ src ⟷ packed** is the whole trick.

- `wb bundle`: external/inline source → tangle → compile → **pack into `wb-bundle`**;
  islands collapse to their packed entries (or stay inline for small text nodes), with
  origin recorded so explode is exact.
- `wb unbundle`: `wb-bundle` → unpack → write tree → **surface islands** as elements
  (or `src`-referenced files) from the manifest.

## Polyglot: bundle = link **+** compile-in-sandbox (already built)

A node's content can be any language because **bundle already tangles + compiles**
(`docs/WORKBOOK-BUNDLE.md` §lifecycle, reusing `OQL.tangle_plan` +
`Workbooks.Build`). This layer only adds a `lang=` hint on an island so the reader
routes to the right existing lane:

- `<work-component lang="svelte" src="./Card.svelte">` → Svelte → custom-element
  module → inlined `<script type="module">`.
- `<work-toolkit lang="rust" src="./tool/">` → Rust → wasm via the mrustc→clang lane
  → packed in `wb-bundle` + a loader.
- `<work-org>` `:component:` blocks → native files (the tangle leg, unchanged).

No new compiler. The `lang=` handler registry is the extension point; each handler is
(compile: source→artifact) + (identity: keep source for lossless reverse).

## Losslessness contract (inherit, don't reinvent)

The byte-exact round-trip is **already pinned** (`bundle_embed_test.exs`,
`bundle_tangle_test.exs`). This layer must not break it, and adds one structure:

1. **An islands manifest** — extend the `workbook-spec` marker with a node table:
   `id → {kind, lang, residence: inline|src|packed, origin path, content-hash}`. The
   reader rebuilds the exact element/file/entry from it.
2. **Source kept, never discarded on bundle** — compiled artifact for *running*,
   source retained (the zip already compresses it) for *reversing*. So
   `explode(bundle(x)) == x` for `.svelte`/`.rs`/`.org` verbatim — same invariant the
   tangle leg already holds (org wins over stale tangled file).
3. **Stable ids + canonical printer** — ids survive the inline⟷src⟷packed swap so
   edges never break; a normalizing serializer keeps same-bytes-out.

## What this explicitly does NOT rebuild

The bundle compiler and its floors are **done and careful** — do not re-derive:

- the `wb-bundle` zip+base64 format, `embed`/`extract`, the browser
  `DecompressionStream` loader;
- `wb bundle`/`wb unbundle`, the tangle (org→native) + compile (native→wasm) legs;
- zip-bomb guard, zip-slip denylist, C2PA signing bound to payload, CSP, private
  boundary;
- the `#+REQUIRES` transitive closure resolver.

## Roadmap — P0–P3 BUILT

The layer is implemented in `runtime/host/bundle_islands.ex` (`Workbooks.Bundle.Islands`),
pinned by `runtime/test/bundle_islands_test.exs` (16 tests, hermetic — the agent leg
runs the REAL embedded OQL kernel, no network/LLM). It adds **no new IO** and rewrites
none of `Workbooks.Bundle`/`AgentDef`/`Toolkits`.

- **P0 — island reader. DONE.** `index/1` classifies a workbook tree
  (`%{"path" => bytes}`, the `Bundle.unpack` shape) into typed islands and `render/1`
  emits them as `src=`-referenced `<work-*>` elements; `parse/1` pulls islands back out
  of hand-authored HTML and `materialize/2` writes inline bodies to tree files. Pure
  bijection over the tree (the tree is the truth; islands describe it). Kind mapping:
  `<work-agent>`→`AgentDef.parse`, `<work-toolkit>`→`Toolkits.parse_descriptor`,
  `<work-org>`→any other `.org`, `<work-vfs>`→SQLite volume. Non-structural files
  (`.wasm`, assets, page html) are ignored.
- **P1 — inline ⟷ src ⟷ packed. DONE.** The islands manifest (the node table) is
  `to_manifest/2`/`from_manifest/1` (`work-islands/1` JSON: `kind, id, path, residence,
  attrs, sha256 hash`), embedded into a page as an inert `<script id="work-islands">`
  via `embed_manifest/2`/`extract_manifest/1` (idempotent, `</script>`-safe). The
  residence swap is `externalize/2` (inline body → tree file) ⟷ `inline/2` (tree file
  → element body), reversible. Round-trip pinned byte-stable.
- **P2 — round-trip spike. DONE.** The nested-composition test proves the `#+REQUIRES`
  toolkit DAG (agent → toolkit → toolkit) resolves identically from the exploded tree
  and the rendered→parsed bundled islands — both feed the SAME `Toolkits.closure/3` via
  `edges/1` + `toolkit_ids/1`. A bare CLI pre-flight (`git>=2.30`) correctly does NOT
  become a graph edge.
- **P3 — `lang=` handler registry. DONE.** `handlers/0` + `handler_for/1` map a
  `<work-component lang=…>` to an existing build lane (`rust`/`rs`→`:rust`, `c`→`:c`,
  `zig`→`:zig`, `svelte`→`:svelte`, `js`/`ts`/`typescript`→`:js`, `go`→`:go`); aliases
  fold to the canonical lane, unknown → `nil`. `build_plan/1` pairs each buildable
  `<work-component>` with its handler and drops unknown langs. NO new compiler — pure
  dispatch to the lanes the bundle compiler already runs.

### Public surface (`Workbooks.Bundle.Islands`)

`index/1`, `render/1`, `parse/1`, `materialize/2`, `edges/1`, `toolkit_ids/1`,
`to_manifest/2`, `from_manifest/1`, `embed_manifest/2`, `extract_manifest/1`,
`externalize/2`, `inline/2`, `handlers/0`, `handler_for/1`, `component_islands/1`,
`build_plan/1`. An island is `%{kind, id, path, attrs, body}` (body set only for
inline islands).

### CLI wiring — DONE

The bijection is wired into the CLI (`runtime/host/cli.ex`):

- **`wb bundle`** embeds the `work-islands` manifest into the page alongside the
  `wb-bundle` zip — `Islands.embed_manifest(html, Islands.to_manifest(Islands.index(parts), parts))`.
  The manifest `src`-references the packed files, so it's a loss-free projection, not a
  second copy. Reports the island count.
- **`wb unbundle`** restores the tree byte-exact (the `Workbooks.Bundle` guarantee,
  unbroken) and reports the composition (`N agent/toolkit/org/vfs`) read from the
  embedded manifest.
- **`wb islands <in.html|dir>`** dumps the typed `<work-*>` structure — from a bundled
  page's manifest, an inline-`<work-*>` fallback, or by classifying a working dir.

Proven end-to-end by `runtime/test/bundle_islands_cli_test.exs` (a real
agent→toolkit→toolkit+org+vfs tree, hermetic OQL kernel): bundle→unbundle byte-exact,
both markers coexist, the embedded manifest equals the source-tree index, and the
toolkit DAG resolves identically from the bundled manifest. Build-lane dispatch of
`build_plan/1` at bundle time (compiling `<work-component lang=…>` sources) is the next
increment; the plan is computed and available today.

## The anti-waffle rule (state in every agent/author prompt)

> The single `.html` is an **output of `wb bundle`**, never an authoring decision.
> You edit a typed node graph (inline islands, `src`-referenced files, or a working
> tree — all equivalent). `wb bundle` / `wb unbundle` are deterministic, lossless,
> reversible compiler passes over it. Never hand-assemble one HTML "to keep it
> tidy"; run the bundler.
