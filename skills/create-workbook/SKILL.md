---
name: create-workbook
description: Create a new single-file HTML workbook systematically — not by vibes. Choose a frontend framework, identify and convert WASM dependencies through the compilers / package-manager lane, confirm a design style against the canon palette, scaffold, and verify. Use when asked to build / make / start a new workbook or HTML mini-app. For planning a fuzzy idea first, defer to the `workbooks` planning skill; for editing an existing one, use edit-workbook.
---

# Create a workbook

A workbook is one portable `.html` artifact that bundles its own source, its UI,
and — when it computes — a real WebAssembly kernel. Build it **systematically**:
every step below is a gate. Skipping a gate is how you end up hand-editing a
runnable artifact or smuggling a native dependency into a WASM-only world.

> Read `skills/workbooks-system/SKILL.md` first if you haven't. For a fuzzy
> idea that still needs scoping/data-sourcing, run the `workbooks` planning
> skill **before** this one.

## 1. Frame the projection

Decide the runnable / source / archive boundaries up front.

- **LAW: never hand-edit the runnable artifact.** Edit source, then bundle.
- The loop is always **unbundle → edit source → rebuild**. Bundle ⇄ unbundle is
  lossless and first-class.

## 2. Pick a framework — explicitly

Record the choice and the reason (bundle size, reactivity need).

- **Default:** Svelte 5 (runes) + Vite with `base: './'` (relative asset paths
  so a dumb static server serves the artifact). This is the lander precedent.
- SolidJS or vanilla are allowed for smaller/leaner needs.
- **No framework at all** for a static data sheet.

Detail: `references/frameworks.md`.

## 3. Inventory compute + WASM deps

List every dependency the workbook needs, then classify each against
`references/wasm-deps.md`:

- **Interpreted** (qjs / python / ruby / lua / yaegi) → already in-sandbox.
  `wbx toolkit build palette [<runtime>]`, invoke directly.
- **Compiled** (C / Zig / Rust) → the compiler itself runs in WASM.
  `wb-rt compiler build <lang>` then `wb-rt compiler run`. Recipes:
  `runtime/compilers/<lang>/`.
- **npm / crate** → resolve → bundle → WASM via the PackageManager lane.

**RULE: no native execution.** Every dep becomes a capability-gated WASM
command. If a dep cannot convert, **FILE an issue — do not fake it** and do not
fall back to OS bash.

## 4. Confirm the design style

Apply the canon (full tokens + the glyphs wiring snippet in
`references/design-canon.md`):

- Green `#3fe081` (dark) / `#149157` (light), paired with **INK text, not white**.
- Blue is **one tint only**.
- **Geist + Geist Mono**; titles are serif + Geist, size-matched (**no mono in
  titles**).
- ASCII shader + grid textures. **Never** component-library defaults.
- Brand/agent marks via the **glyphs resolver** — never ad-hoc inline SVG.

## 5. Scaffold

Use the standalone artifact CLI (the `workbooks-authoring` skill owns
`workbook`, a **separate** tool from `wbx`):

```sh
workbook init
```

Wire the glyphs resolver if marks are needed: alias `$glyphs` →
`toolkits/glyphs/dist/glyphs.js`, then `configure({ brands, icons, svglIndex, … })`
**once**. Snippet in `references/design-canon.md`.

## 6. Verify at the tightest tier

```sh
workbook dev          # run locally
workbook build        # bundle
workbook check        # or: wb content check [dir]
```

Re-read the changed file. Confirm the runnable contains **no raw inputs** and
the source **unbundles losslessly**. **Never await CI** — prove it at the
tightest tier that demonstrates the change.

## References

- `references/frameworks.md` — framework choice guidance.
- `references/wasm-deps.md` — the dependency-conversion decision table.
- `references/design-canon.md` — tokens + the glyphs wiring snippet.
- `references/cli.md` — the `workbook` vs `wbx` split.
