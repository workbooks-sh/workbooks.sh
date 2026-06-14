# The Workbook Bundle Standard

> Reconstructed 2026-06-14 after the artifact model drifted (a desktop-only Tauri
> command was the last remnant; the compressed-fs-in-html core had been lost).
> This is the canonical standard. Implementation lands incrementally against it.

## What a Workbook is

A Workbook is **one `.html` file** that carries its **entire filesystem inside it**,
compressed. The same single file is:

- a **page** you can open/serve (the rendered, runnable workbook), and
- a **data store / archive / context-repository** (its filesystem — org source,
  native code, binary assets, SQLite volumes — packed and compressed within).

Hand someone one `.html` and they have everything. No sidecar `.wbundle`, no server.

## The format

The filesystem is embedded as a single base64 block:

```html
<script type="application/zip" id="wb-bundle" data-encoding="base64">…base64…</script>
```

- The payload is a **zip** (`Workbooks.Bundle.pack/1` — `:zip.create`), so every entry
  is **deflate-compressed**. The zip *is* the "gzip folder architecture": a directory
  tree of files, each compressed, in one blob. Binary-safe (SQLite, images, `.wasm`).
- base64 makes it HTML-safe. base64's alphabet excludes `<`, so the payload **cannot
  break out of the `<script>` tag** — no escaping, injection-inert (pinned by test).
- The surrounding HTML is the page (rendered workbook, or a thin loader shell).

Why zip/deflate and not zstd/xz: a served workbook must **unpack itself in a browser
with zero dependencies**. Browsers ship `DecompressionStream('deflate-raw' | 'gzip')`
natively; **zstd/xz are not browser-native**. deflate is decodable identically by the
browser, the Elixir host (`:zip`/`:zlib`), and the wasm sandbox — one format everywhere.
(A whole-bundle gzip wrapper for max compression of huge archives is a deferred option;
it would double-compress the already-deflated zip, so it's opt-in only.)

## The primitive (built)

`Workbooks.Bundle` (`runtime/host/bundle.ex`):

- `embed(html, blob) -> html'` — inject/replace the `wb-bundle` block (idempotent).
- `extract(html) -> blob | nil` — pull the embedded bundle back out.
- `embedded?(html) -> bool`.
- (existing) `pack(parts) -> zip`, `unpack(zip) -> parts`, `ship/restore`, `open` (sealed).

Full round-trip, pinned by `runtime/test/bundle_embed_test.exs`:
`tree → pack → embed → extract → unpack → tree` is byte-exact.

## The lifecycle — bundle / unbundle as the workbook compiler

Bundling is a **native part of every workbook**, not a one-off export:

1. **unbundle** (`.html → working tree`): `extract` then `unpack` the zip to files —
   the org source plus its tangled native code (Svelte / JS / Rust …).
2. **edit**: work on the native files directly — you edit *source*, not compiled `.wasm`.
3. **tangle + compile**: org code blocks → native files (kernel `tangle_plan`); native
   files → `.wasm` via the in-sandbox compiler lanes (C/Zig/Rust+std, all already built).
4. **bundle** (`working tree → .html`): `pack` the tree → `embed` into the page html.
   Idempotent, so re-bundling after edits replaces the old payload cleanly — this is
   how edits are preserved and how a workbook is "managed."

This is the workbook compiler: literate org + native source in, a self-contained
runnable `.html` out, with the heavy/binary parts compressed.

## Native everywhere (the de-Tauri rule)

The canonical implementation is the **runtime + CLI + kernel/sandbox** — NOT a desktop
Tauri command. The desktop *calls* the canonical path; it does not own it.

| Tier            | How it unpacks `wb-bundle`                                  |
|-----------------|------------------------------------------------------------|
| Host / CLI      | `Workbooks.Bundle` + `:zip` (Elixir)                        |
| Agent (sandbox) | the in-guest wasm zip lane (intent in, no native exec)      |
| Browser (serve) | `DecompressionStream('deflate-raw')` per zip entry, in JS   |
| Desktop         | invokes the runtime/CLI path — no bespoke Rust bundler      |

## Publish / serve

A published workbook is served as the single `.html` with `wb-bundle` embedded. On
load, a small client loader reads the `wb-bundle` script, base64-decodes, walks the zip
central directory, and `DecompressionStream`s each entry to hydrate the in-browser VFS —
**fully self-contained, no server round-trip**. (The control plane MAY hydrate
server-side instead when it owns the session, but the self-contained client path is the
default and the reason deflate was chosen.)

## Status & remaining work

- [x] Primitive: `embed`/`extract`/`embedded?` + byte-exact round-trip test.
- [ ] CLI: `wb bundle <dir> <out.html>` / `wb unbundle <in.html> <dir>` over the primitive.
- [ ] Browser loader: zip-central-dir reader + `DecompressionStream` hydrate.
- [ ] Agent sandbox: in-guest unbundle/bundle (wasm zip lane) for the edit loop.
- [ ] De-Tauri: route `workbook_bundle`/`workspace_package` to the canonical path.
- [ ] Tangle/compile wiring into the bundle lifecycle (org ↔ native ↔ wasm).
- [ ] Migrate the separate `.wbundle` egress to the embedded form (keep `.wbundle`
      readable for back-compat; new artifacts are self-contained `.html`).
