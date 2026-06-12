# The products — what ships, and as what

Workbooks reaches people as two products built from one open-source codebase
(Apache-2.0):

## 1. The repository — the ecosystem

The open-source monorepo carries every layer a builder can adopt piecemeal
or whole:

- **The runtime** — the Elixir/BEAM engine: serves workbooks, hosts agents,
  executes all compute as WebAssembly on wasmtime. Ships as one OCI image
  (built by CI); Deploy Kit runs it anywhere → `deploykit.md`.
- **The `wbx` CLI** — one binary for the whole surface: authoring, bundling,
  deploying, toolkit ops, engine ops → `cli/index.md`.
- **Compiler lanes** — in-sandbox toolchains (C, Zig, Rust, JS/TS/npm) that
  turn source into the WASM the platform runs → `toolkit.md`.
- **Toolkits** — the capability/skill packages agents and workbooks consume.
- **The desktop app source** — the app below is built from this same repo.

Everything is inspectable; deployed sites built on the platform typically
publish their own tenant repos too, because every deploy is a git commit.

## 2. The desktop app — the front door

A signed, cross-platform desktop application (macOS / Windows / Linux;
Tauri-based) that puts the ecosystem on one machine with no server, no
account, and no cloud dependency:

- **Workbook-native**: embeds the kernel (`oql.wasm` on wasmtime) directly —
  it weaves, renders, and runs workbooks locally. Viewing a workbook never
  requires a server.
- **Offline-first boot**: the app starts without any engine; a runtime
  connection (local or remote) is an optional tier for agents, sync, and
  shared engines — its state is shown, never a blocking gate.
- **The working surface**: workspace and sessions, an org renderer and
  viewer for workbook source, a board (task/workflow view), chat with
  agents, a command palette, sharing, and setup/integration wizards.
- **The provider seam**: the same UI runs against the local OS, a connected
  runtime, or the in-process kernel — a deployment target is a routing
  config, not a separate app.

Positioning note for anyone writing about the products: the website sells
the desktop app; developers are routed to the repository. A hosted cloud is
a planned tier — never promise it as available.

## Which one is "the product"?

Both, by audience: builders adopt the repo (runtime + CLI + toolkits);
everyone else installs the app. They are the same ecosystem at two doors —
an app made in the desktop app runs on a deployed runtime unchanged, because
both execute the same artifacts the same way.
