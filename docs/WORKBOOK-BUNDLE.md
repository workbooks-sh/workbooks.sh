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
- [x] CLI: `wb bundle <dir> <out.html>` / `wb unbundle <in.html> <dir>` over the primitive (`Bundle.read_tree`/`pack`/`embed`, `extract`/`unpack`/`write_tree`; path-confined; `test/bundle_cli_test.exs`).
- [x] Browser loader: zip-central-dir reader + `DecompressionStream('deflate-raw')` hydrate, dependency-free (`web/wb-bundle-loader.js`). Served pages inject it via `PublicWeb.static_doc`; offline/CLI-built `.html` get it via `Bundle.embed_loader/1` (classic-script form, ONE source). Reads `wb-bundle`, base64-decodes, walks the central dir (EOCD→CDH→LFH), inflates per entry → in-memory VFS Map, dispatches `wb:hydrated`. Tests: `web/wb-bundle-loader.test.js` (node --test, real zip round-trip) + `runtime/test/bundle_loader_test.exs` (loader present + well-formed in a served page).
- [x] Agent sandbox: in-run unbundle/bundle for the edit loop, host-brokered — NOT a wasm zip lane. The agent emits the intent (`wb unbundle <in.html> <dir>` → edit native source → `wb bundle <dir> <out.html>`) over its `wb` tool surface; the host performs the `:zip` IO via the SAME `Workbooks.CLI`/`Workbooks.Bundle` clauses the CLI uses (DRY — one Bundle home, no second zip lane; the js_dock brokered-IO precedent, zero native exec). Both verbs are exec-gated (`@effectful_wb` in `agent.ex`) since they read/write raw caller paths. Test: `runtime/test/agent_bundle_loop_test.exs` (full unbundle→edit→re-bundle round-trip through the agent tool + the exec gate). A fully in-guest path, if ever wanted, routes through a brokered `host_zip` import (intent in, host runs `:zip`) — never a native unzip binary.
- [x] De-Tauri: route `workbook_bundle`/`workspace_package` to the canonical path. The phantom `workbook_bundle`/`workbook_unbundle` Tauri commands (invoked by the Svelte bridge but never implemented in Rust) are gone; `workbook_io.svelte.ts` now drives the engine's `Workbooks.Bundle` over `POST /rcp/bundle` + `POST /rcp/unbundle` — the BYTES-over-RCP seam checkout/checkin use (the engine runs in a container, so trees move as bytes, never as engine-side paths). The desktop owns NO bundler: it only does file IO via `bundle_read_tree`/`bundle_write_tree` (raw bytes, base64, the SAME private-path strip + `..`-confinement as `Bundle.read_tree`/`write_tree`); the engine does all zip/embed/loader/sign. `workspace_package` (network.rs) no longer renders org locally + appends a bespoke `<!-- wb-signature -->` comment (drift: a `.html` with NO embedded filesystem); it gathers the workspace tree and calls `/rcp/bundle?sign=1`, so the egress is the SAME self-contained, `Workbooks.Manifest`-signed (C2PA) `.html` the CLI/runtime produce. Tests: `runtime/test/bundle_rcp_test.exs` (binary-safe round-trip + verifiable C2PA sign + no-bundle error). Verified: runtime `mix compile` + the bundle test suite green; desktop Rust `cargo check` clean (past a pre-existing unrelated `mod mcp;` gap on this branch). NOT verified: a full desktop build/run (frontend deps + svelte-check + Tauri build) — needs a desktop build to confirm the wired invoke seam end-to-end.
- [x] Tangle/compile wiring into the bundle lifecycle (org ↔ native ↔ wasm). `wb bundle` is now the workbook compiler: it (a) tangles the org source-of-truth → native source via `Bundle.tangle_files/1` — the org→native EMITTER alongside the kernel's plan-only output, REUSING `OQL.tangle_plan` (each `:component:` block's body written to `<dir>/<name><ext>`; org wins over any stale tangled file, so re-tangle is idempotent and the "edit source not compiled wasm" invariant holds); (b) compiles native → `.wasm` via `Bundle.compile_tree/2`, which REUSES `Workbooks.Build.build` (→ `PackageManager`/`Compilers`: mrustc.wasm→clang.wasm for Rust, C/Zig, `js_compile_to_wasm`) on a throwaway tree — the same lane driver behind `Library.build_projection`, never a re-derived compile loop; (c) packs the tree INCLUDING the org (re-editable), the tangled native, and the compiled `<name>.wasm` (the `Library.install/3` shape `CommandRegistry` registers) → `embed` into the page. `--no-build` packs source-only (the tangle still runs, so native stays in sync with the org). Test: `runtime/test/bundle_tangle_test.exs` — the org→tangle leg runs the REAL embedded OQL kernel (hermetic, no network/LLM); the heavy compile is asserted at the wiring level (buildable-detection + `build: false` skip) so the default run needs no toolchain, with the full end-to-end compile behind the `:build` tag (`mix test --include build` in a provisioned env). Verified: `mix compile` clean + `mix test test/bundle_tangle_test.exs` (6 pass, 1 `:build`-excluded) + the existing bundle/oql suites green (no regression).
- [x] Migrate the separate `.wbundle` egress to the embedded form (keep `.wbundle`
      readable for back-compat; new artifacts are self-contained `.html`). `Bundle.ship/4`
      defaults to `egress: :html` — it packs the FILESYSTEM (vfs + manifest + sealed
      entries; the page is the carrier, NOT packed → no circular self-embedding) and
      `embed`s it into the page; `egress: :wbundle` returns the legacy raw zip. `Library.pack/3`
      defaults to the embedded `.html` (picks `index.html`/`workbook.html`/rendered
      `workspace.org` as the page); `Library.store/3` keys new stores `<slug>.html` and
      reads both. A `Bundle.read_any/1` dispatcher (raw zip starts `PK`; else `extract`
      the wb-bundle block) makes `restore`/`open`/`verify`/`install`/`Library.unpack`
      accept BOTH forms transparently — no flag-day, old artifacts keep opening. Tests:
      `runtime/test/bundle_egress_migration_test.exs` + the updated `bundle_ship_sealed_test.exs`
      (legacy sealing pinned at `egress: :wbundle`). Inferred-security floor below.
- [x] **Inferred security adjacents** (shipped alongside the migration, see
      `docs/BUNDLE-INFERRED-ITEMS.md`):
  - **Zip-bomb / decompression guard (ACTUAL-output, not declared)** — `Bundle.unpack`
    does NOT trust `:zip.list_dir`'s declared sizes (a forged central dir declaring
    100 B could inflate to 30 MB+ via `:zip.extract` and bypass a declared-size cap →
    BEAM OOM). It parses the zip itself and raw-inflates each entry via
    `:zlib.safeInflate` in bounded chunks, enforcing a hard PER-ENTRY (256 MB) +
    RUNNING-TOTAL (512 MB) cap on ACTUAL output and ABORTING before materializing
    past it. Caps are configurable (`:workbooks, :bundle_max_total_bytes` /
    `:bundle_max_entry_bytes`); the guard governs every host unpack path. The JS
    loader (`web/wb-bundle-loader.js`) likewise caps actual inflated output. Tests:
    `bundle_security_poc_test.exs` (forged 100 B-declared → 30 MB REJECTED) +
    `bundle_egress_migration_test.exs` + `web/wb-bundle-loader.test.js`.
  - **Path-traversal (zip-slip) + control-dir denylist** — `Bundle.write_tree`'s
    `safe_member?` rejects absolute / `..` entry names (CLI `with_org_file`
    confinement), AND it applies the SAME `@strip_segments` denylist `read_tree` uses
    (`.git`/`.beads`/`node_modules`/`_build`/`.tmp`/`.private`) — a hostile bundle
    smuggling `.git/hooks/pre-commit` (code-exec on the next git op) is REFUSED, not
    just `..`-confined. `Library.unpack` + `wb unbundle` both route through it. Pinned
    in `bundle_security_poc_test.exs` + `bundle_cli_test.exs` + `bundle_egress_migration_test.exs`.
  - **Manifest signing over the embedded form (bind + fail-closed)** — `Manifest.sign`/
    `verify` hash the page with the wb-bundle block STRIPPED (signature invariant
    under embed/extract; wb-bundle + a `workbook-spec` marker coexist), so the
    signature alone does NOT cover the payload. EVERY embedded-form signing path binds
    the blob with a signed `wb.bundle.sha256` assertion (`bundle_sha_assertion_for/1`):
    `ship(egress: :html)`, RCP `POST /rcp/bundle?sign=1` and `Library.checkin` (via
    `Bundle.sign_embedded/1`). And `Bundle.verify/1` FAILS CLOSED (`valid: false`,
    `bundle_unbound: true`) on a signed embedded form with NO such assertion; a
    swapped payload yields `bundle_integrity: false`. Pinned in
    `bundle_security_poc_test.exs` + `bundle_egress_migration_test.exs`.
  - **CSP + inert-payload on served pages** — `PublicWeb.serve_html` sets a
    `Content-Security-Policy` (`default-src 'self'`, `object-src 'none'`, `base-uri
    'self'`); hydrated VFS entries are DATA, not scripts, until the runtime explicitly
    evaluates them. The `wb-bundle` block is `type=application/zip` (non-executable).
  - **Private/session boundary on the raw-tree egress** — `Bundle.read_tree` (the
    `wb bundle <dir>` source) now consults `Workbooks.Private.private?/1`, so secrets
    / agent-memory / session sidecars don't get embedded into a shared `.html`.
    Pinned in `bundle_egress_migration_test.exs`.
