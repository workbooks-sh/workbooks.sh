---
name: workbooks-kit
description: Set up, author, and ship a workbook end-to-end with the real `work` CLI. The dogfood path — one HTML file built from `work-*` elements, with `<work-src>` logic compiled to WASM by the Dock, bundled to a single self-contained `.html`, and deployed locally. Use when asked to "make a workbook", add a `work-*` component, run a `work-src` source block, bundle a workbook, or deploy one locally. Covers create → add component → run work-src → bundle → deploy. For framework/design-canon depth use create-workbook; for the platform concepts use workbooks-system.
---

# Workbooks kit — set up, author, deploy with `work`

A workbook is **one HTML file** (or a folder of them) built from `work-*` custom
elements. The browser renders it — there is no kernel, no org-mode, no `.work`
parser. Logic is written **inline** as `<work-src lang="…">…</work-src>` and the
**Dock** compiles it to WASM. Shipping is `work bundle`: the folder tree woven
into one gzipped self-contained `.html`.

This skill is the **dogfood lifecycle** run entirely through the canonical `work`
CLI (the Elixir escript). Every command below is a real verb — cross-check
`references/work-verbs.md`. Do them in order; each stage has its own reference.

> No runtime is needed to author or view a workbook — it renders client-side.
> A runtime is only needed for the compiler lane (`<work-src>` → WASM), agents,
> and deploy. Don't gate authoring on standing a server up.

## The five stages

1. **Create** a workbook — scaffold the HTML + verify it. `references/create.md`
2. **Add a `work-*` component** — compose elements as HTML. `references/components.md`
3. **Run a `work-src`** — compile inline source to WASM via the Dock. `references/work-src.md`
4. **Bundle** — weave the tree into one `.html`. `references/bundle.md`
5. **Deploy local** — stand the runtime up and ship it. `references/deploy.md`

## 1. Create

Author plain HTML using `work-*` elements; the page IS the workbook. Validate
structure and content non-interactively:

```sh
work structure index.html      # list the work-* elements + ids (the outline)
work content check .           # validate the folder (HTML-first; no JSON)
```

Details + the minimal starter page: `references/create.md`.

## 2. Add a `work-*` component

Nest a themed element and pass scalars/refs as **attributes**, content as
**children** — composition-as-source, never JSON. Re-run `work structure` to
confirm it's discovered. `references/components.md`.

## 3. Run a `work-src`

Write logic inline: `<work-src lang="rust|c|zig|python|js">…</work-src>`. The
Dock compiles it. Drive the compiler lane directly:

```sh
work compiler list                  # languages the Dock can build
work compiler build rust            # build the language's WASM compiler
work compiler run rust src/main.rs  # compile + run a source file → WASM
```

To promote an inline block into a reusable kit command:
`work kit build-inline <name> <lang> <file>`. Details: `references/work-src.md`.

## 4. Bundle

Weave the folder into one self-contained `.html` (the `wbundle-html/1` format);
`unbundle` recovers the tree losslessly:

```sh
work bundle . dist/index.html       # tree → single gzipped .html
work unbundle dist/index.html out/  # round-trip back to source (lossless)
```

Details: `references/bundle.md`.

## 5. Deploy local

```sh
work dev info                       # demo dashboard: runtime target + /health, key, toolkits
work deploy local                   # zero-config local run (same OCI image as prod, krunvm)
```

The declarative path (scaffold → edit → validate → apply → status/down) is in
`references/deploy.md`. `work deploy` is the **user's** tool to run the runtime
image — never a platform-release mechanism.

## References

- `references/work-verbs.md` — every `work` verb this skill uses (the contract).
- `references/create.md` — scaffold + the minimal `work-*` starter page.
- `references/components.md` — composing `work-*` elements as HTML.
- `references/work-src.md` — the `<work-src>` → WASM compiler lane.
- `references/bundle.md` — bundle / unbundle round-trip.
- `references/deploy.md` — `work dev` + `work deploy` local lifecycle.
