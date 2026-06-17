# Notes — work-format & naming (scratch, not canon yet)

Running idea-park for the workbook-authoring exploration. **Not a memory, not a decision** —
just so we don't lose track. Nothing here is sacred; simplify aggressively.

---

## 1. Naming rework (proposed — resolve later)

We over-specified names. Working proposal to make them plainer / more standard:

| Today | Proposed | Reasoning |
|---|---|---|
| **toolkit** | **component** | they're (mostly) web components / distributable element sets |
| **Dock** (the host capability membrane) | **assembly** | WebAssembly *is* the dock; the dock assembles the weave |
| **wasmtime / WASM runtime instance** | **container** | a wasm instance is really just a web container — call it that |

**Collisions to resolve before adopting (don't skip these):**
- *component* already means our `work-*` custom elements. If toolkits become "components,"
  disambiguate **component (a packaged toolkit/dep)** vs **element (a single custom tag)**.
- *assembly* also reads as the **weave/build step** ("assembling the bundle"). Risk of conflating
  the **membrane** (Dock) with the **act** (assembly). Maybe membrane=assembly, step=weave.
- *container* already means the **OCI/krunvm deploy container** (the whole runtime image). Two
  scopes of "container": the wasm instance vs the OS container. Qualify them.

Likely want to "split up some of this stuff" too — i.e. the membrane may be more than one concept.
Park it.

---

## 2. The index — what it's actually FOR (corrected)

The index is **not** where content/views/tasks primarily live. It's the **app skeleton + build/validation
+ dependency/target manifest**. Three jobs:

1. **Skeleton** — set up the *entire app structure* in one index file. The shell.
2. **Validation gate** — structured validation + types over the **tangle/compilation**: assert the
   pieces fit ("everything assembles well together"). This is where types/requirements get declared.
3. **Imports / packages / tangle management** — manage how we pull in deps & packages, how the
   bundle/gzip is shaped, what's front-end vs back-end / client vs server.

Plus:
- **Pinpoint the nexus** — declare the **server target** (where code is validated/compiled, where
  docked/server work runs).
- **Include toolkits** (= external deps) — wire in external **components**. This is where web
  components earn their place in the index.

**Lean on native HTML for the skeleton** (`<section>`, `<a>`, `<p>`); reserve `work-*` elements for the
things HTML can't express (imports, grants, validation rules, work-runs, data bindings, nexus target,
toolkit includes). The index components/templates can be simplified **beyond** what the two-files book
showed. Nothing sacred.

---

## 3. Tasks / workflows / structure → live in the WORK files, NOT the index

Correction to the two-files book (I wrongly put the board/PM in the index). **Tasks, workflows, and
structure are authored in the same files as the code** — mixed directly into the work-file's literate
body. A work file is richer than "a compute unit": it carries content + structure + tasks + workflows
+ code together. The index just *assembles* them.

→ Fix the two-files example accordingly.

---

## 4. The weave is POLYGLOT — incl. front-end frameworks

Don't make examples Rust/Elixir-deterministic. The weave compiles **front-end code too**:
JS, Solid, Svelte, Astro, whatever. So a unit's lane can be `svelte` / `solid` / `js` and the weave
produces client islands; server lanes (`rust`/`elixir`/`orb`) produce wasm/BEAM. Reinforces islands:
front-end-framework components become hydrated islands. Keep examples lane-agnostic.

---

## 5. OPEN — package management

Multiple packages to install — how managed, and **where declared** (in source blocks, or elsewhere)?

Working answer (not locked):
- **Declared at the boundary, used in the source.** A source block may `use regex` / `import x`, but the
  *resolution* (name, version, registry) is **declared**, not buried in arbitrary source — so the weave
  gate (job #2) can **audit the dependency graph**. Same reason caps are declared.
- **Two scopes, same inline↔reference dial:**
  - **app-level** deps + toolkit includes + registries → declared in the **index** (the skeleton's
    dependency manifest).
  - **unit-level** deps → the **work file's frontmatter** (the unit owns its deps, colocated).
- **NO package.json** (no-JSON rule). Deps are HTML elements in the index
  (`<work-package …>` / `<work-import kit="…">`) and frontmatter in work files.
- **Toolkits = external component deps** — included in the index like a component library
  (a prefix + its elements + its caps), per the existing work-kit model.

Resolve: exact element/attr shapes; lockfile story; how registries are pinned.

---

## 6. Carry-overs still true

- `index.html` (skeleton) + `*.work` (literate units, markdown + typed fenced code) → weave → one
  self-contained HTML (page + gzip blob).
- `.work` flavor = **markdown + typed fenced code**; types/guarantees live at the **weave gate**, not
  in the surface syntax.
- Security: code-in-bundle fine; secrets/gated-data never in a static file; caps are *requests* the host
  authorizes; postures public / gated_data / gated_route.
- Server regions SSR from the BEAM (the "htmx for Elixir literate programming" lane); client regions
  hydrate as islands.
