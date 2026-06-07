# workbooks.sh

The Workbooks runtime — a single Elixir server (~6k LOC) that runs WASM
components on the BEAM. The runtime is the whole concept: author a Workbook as
Org, and the engine renders it, runs its components in-WASM, drives long-horizon
agents, and ships a single-file `.html` deliverable.

## Layout

| Dir         | What                                                                 |
|-------------|----------------------------------------------------------------------|
| `runtime/`  | **the product** — the `:workbooks` engine. Elixir host in `host/` (the agent loop, OQL, VFS, BrandBook pipeline, web surface), the OQL kernel (Rust → `build/oql.wasm`) in `kernel/`, WIT worlds in `wit/`, baked wasm commands in `build/commands/`. |
| `toolkits/` | capability toolkits the engine discovers — incl. `presentation` (reveal.js) and `video` (hyperframes); CLIs wrapped as agent skills. |
| `web/`      | the lander + the workbook viewer.                                     |
| `desktop/`  | the Tauri desktop app (being refactored).                            |

## The runtime

~4.5k LOC Elixir + ~1.3k LOC Rust, self-contained. One container: BEAM +
wasmtime + the baked wasm artifacts. `runtime/host/` is the entire server —
the agent loop calls an LLM ↔ tools (a sandboxed in-WASM shell, the VFS, fetch,
and real toolkit CLIs), every step appended to an OQL-queryable `events.org`.

```
cd runtime
mix deps.get && mix compile
iex -S mix          # or: MIX_ENV=prod mix release
```

Deploy: `runtime/Dockerfile` + `runtime/fly.toml`.

## What this isn't

Everything that used to crowd the monorepo — the legacy engine, the unused
services, the old substrates, the CLI — is gone. The CLI may be ported back into
the runtime later; the brandnana brand-book toolkit lives in its own repo and is
invoked as an external CLI. This repo is the runtime and the surfaces that ride
directly on it.
