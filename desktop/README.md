# Workbooks Desktop

A **workbook-native** desktop app: a lean Tauri shell that renders/edits/runs
workbooks **locally** via the embedded OQL kernel — no server, no Docker. The
Elixir runtime is the *optional* server tier (agents, multi-tenant, cloud sync),
connected to only when you want those features.

## The two tiers

| Tier | What | Needs |
|------|------|-------|
| **The app (default)** | Tauri (Rust) + the OQL kernel (`oql.wasm`, embedded) + the Svelte frontend. Open / edit / weave / validate / outline workbooks. | **Nothing else** — offline, instant. |
| **The runtime (optional)** | Agents, multi-tenant, HTTP/WS control plane, vectors, cloud sync. The Elixir BEAM in a container, via the deploy-kit (`wb deploy`). | A running runtime (local krunvm *or* cloud). |

The app **never** requires the runtime to open a workbook. Starting it is explicit
(tray "Start / restart engine", or opening an agent feature).

## How it works

- **`src-tauri/` (Rust shell)** — does only what a browser can't:
  - `kernel.rs` — embeds `oql.wasm` (the same 414 KB component the Elixir runtime
    loads) and runs it via `wasmtime` + `wasmtime-wasi`. Exposes `weave`, `tangle`,
    `validate`, `lint`, `outline` as Tauri commands — **fully in-process**.
  - `daemon.rs` + `machine.rs` — the engine bridge. Boots the runtime the same way
    `wb deploy local` does (a libkrun microVM via `krunvm`) but **natively from Rust**,
    so a fresh install needs only the krunvm backend — no Erlang, no `wb` escript.
    Reads the runtime discovery file (`{host, port, token}`); the install wizard
    (`src/lib/setup/`) drives the `engine_*` commands (detect / install-backend /
    boot-local / connect-cloud).
  - `lib.rs` — commands + tray + window (close → hide; frameless overlay titlebar so
    the app's nav bar *is* the window chrome); file `read_file`/`write_file`.
- **`src/` (Svelte frontend)** — the same SPA runs in a plain browser (mocks) and in
  the shell (live), detected by `isTauri()`:
  - `lib/kernel.ts` — local weave/tangle/validate/outline (the workbook-native core).
  - `lib/files.ts` — open/save `.org` via the native dialog + Rust IO.
  - `lib/runtime.ts` — the OPTIONAL runtime client (HTTP/WS to the discovered URL).
  - `lib/views/WorkbookView.svelte` — the editor: live weave + validate + outline as
    you type, New/Open/Save (⌘N/⌘O/⌘S). The "Workbook" rail tab.

## Develop

```bash
bash scripts/dev.sh        # builds the wb escript + `tauri dev` with WB_BIN set
# or:
bun run build              # frontend → dist/
cargo test --manifest-path src-tauri/Cargo.toml   # kernel weaves Org → HTML, in-process
```

The dev server is pinned to **:5178** (`vite.config.ts` strictPort), matched by
`tauri.conf.json` `devUrl`.

## Build / ship

```bash
bun run tauri build        # → unsigned .dmg
```

Not yet shippable: needs (1) an Apple signing cert (codesign/notarize), and (2) a
decision on bundling `wb` — the deploy-kit escript needs Erlang, so either Burrito-
wrap it (bundle ERTS) or reimplement deploy natively in Rust. The image the runtime
tier pulls is `ghcr.io/workbooks-sh/runtime` (must be public for anonymous pull).

## North star

The app's own UI becomes a workbook the kernel renders — a gradient
(content → views → chrome), each step gated on the workbook *format* growing its
interaction layer (the WASM "Dock" component model). Today the Svelte app is
scaffolding; the line moves toward "all workbook" incrementally.
