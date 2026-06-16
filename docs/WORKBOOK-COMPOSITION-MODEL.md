# The Workbook Composition Model

> The **declarative composition layer** over the already-built bundle compiler.
> Read `docs/WORKBOOK-BUNDLE.md` first — that is the canonical, byte-exact,
> security-hardened `bundle`/`unbundle` compiler (`Workbooks.Bundle`, `wb bundle`/
> `wb unbundle`). This document does **not** re-derive any of it. It specifies a
> thin layer: expressing a workbook's structure as **typed config-island custom
> elements** so composition is legible *as HTML/DOM* and authorable by hand or by a
> one-shot model — while every node still rides the existing tangle → compile → pack
> → embed lifecycle and inherits its losslessness + security floors verbatim.

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

## Roadmap

- **P0 — island reader.** A host-side reader (`Workbooks.Bundle.Islands`?) that, on
  `unbundle`, surfaces `<work-org>`/`<work-agent>`/`<work-toolkit>`/`<work-vfs>` from
  the tree+manifest; on `bundle`, collapses them back. Pure mapping over the existing
  `Bundle` primitives — no new IO, no new zip lane.
- **P1 — inline ⟷ src ⟷ packed.** Implement the three-residence swap + the islands
  manifest; pin the byte-exact round-trip the same way the existing tests do.
- **P2 — round-trip spike.** One hand-authored example: an agent HTML referencing a
  toolkit referencing a toolkit, an `.org` file, and a `lang="svelte"` component.
  Prove `bundle`→`unbundle`→`bundle` is byte-exact and the agent/toolkit DAG resolves
  identically from both the bundled and exploded forms.
- **P3 — `lang=` handler registry.** Generalize beyond the tangle leg's component
  shapes (Svelte/Rust/JS already have lanes); register the source↔artifact handlers.

## The anti-waffle rule (state in every agent/author prompt)

> The single `.html` is an **output of `wb bundle`**, never an authoring decision.
> You edit a typed node graph (inline islands, `src`-referenced files, or a working
> tree — all equivalent). `wb bundle` / `wb unbundle` are deterministic, lossless,
> reversible compiler passes over it. Never hand-assemble one HTML "to keep it
> tidy"; run the bundler.
