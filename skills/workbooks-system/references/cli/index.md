# The `wbx` CLI — complete command tree, by purpose

`wbx` is one Elixir escript folded into the runtime project. Most commands call
straight into the same modules the runtime uses, so an agent can run `wbx` as an
in-process tool. A few command families (`deploy`, `publish`, `rt`, `ctk`,
`toolkit`-over-RCP, `dev`, `desktop`) are **host-side**: they shell out or speak
HTTP and never boot the BEAM app (which would load the OQL/wasmex NIF an escript
can't host). Those carry exit codes and accept `--json`.

Two ways the same `toolkit` verbs run:
- **In-process** (an agent calling `wbx` as a tool) → `Workbooks.CLI.call/2`, local.
- **From the shipped escript** → `Workbooks.CLI.Runtime.toolkit/1`, server-side
  over `/rcp/toolkit/*` (the escript can't load the NIFs). Same verbs, same output.

Deep files: `workbook.md` · `deploy.md` · `toolkit.md` · `engine.md`.
HTTP routes: `../http.md`. Org-file specs: `../org-specs.md`. Env: `../env.md`.

## Author a workbook (`workbook.md`)

| Command | The need it serves |
|---|---|
| `wb query \| tangle \| lint <file.org>` | turn an Org workbook into headlines / a build plan / diagnostics |
| `wb bundle <src.org> <out>` | pack a workbook bundle (source + manifest) |
| `wbx unpack <bundle> <dest>` | disassemble a parent workbook back into a flat tree |
| `wbx build <workspace>` | compile a workspace's components → WASM; report built/unbuilt |
| `wb pack <workspace> <out> [--build]` | compose a workspace's members into one workbook |
| `wbx sign <file.html> [--out f]` | embed a did:key provenance manifest (C2PA-style) |
| `wbx verify <file.html>` | check an artifact's signature + asset integrity |
| `wbx publish init \| validate \| apply \| site` | render a workbook → live URL |

## Operate / inspect a run (`workbook.md`, `engine.md`)

| Command | The need it serves |
|---|---|
| `wb telemetry [<slug>]` | the runs index, or one run's summary + errors |
| `wb ledger <slug>` | verify a run's signed ledger (tamper-evidence + attribution) |
| `wb search <query> [--semantic\|--literal] [--workbook s]` | recall by meaning ∪ literal across a library |
| `wbx library [query <sql>]` | list workspaces+members, or cross-workbook query |
| `wb checkout \| checkin <member> <workdir>` | borrow a member out / pack it back in |
| `wbx store \| stored \| fetch` | durable storage on the configured backend |
| `wb mirror \| radicle` | mirror the tenant repo to a git host / federate over P2P |

## Operate an engine (`deploy.md`, `engine.md`)

| Command | The need it serves |
|---|---|
| `wbx deploy init\|validate\|apply\|status\|verify\|logs\|down` | declarative local/cloud runtime lifecycle |
| `wbx deploy local \| doctor` | zero-config local run; check + self-heal prereqs |
| `wbx deploy build \| publish` | build / push the one runtime OCI image |
| `wbx rt status\|get\|post` | drive a *running* runtime over HTTP (RCP client) |
| `wbx ctk await <run>` | block until a human CTK review lands, then print it |
| `wbx desktop install\|open` | install / launch the desktop GUI app |

## Extend capabilities (`toolkit.md`)

| Command | The need it serves |
|---|---|
| `wbx toolkit list\|show\|search` | discover toolkits + read skill recipes progressively |
| `wbx toolkit verify\|eval` | structural + satisfiability checks; run a toolkit's eval suite |
| `wbx toolkit build [which]` | declarative auto-wrap: build `#+BUILD_SRC` → register a command |
| `wbx toolkit build-inline <name> <lang> <file>` | self-author a source file → a session command |
| `wbx toolkit promote <name> <lang> <file>` | promote a session command → a durable workspace toolkit |
| `wbx toolkit run <id> <task> -- <args>` | run a skill's `:role task` block with positional args |
| `wbx toolkit sign <id>` | sign a toolkit with the tenant's did:key |
| `wb-rt compiler list\|build\|run` | the in-WASM compiler lane (C/Zig/Rust/JS/…) |
| `wb isolation` | show the isolation-tier ladder |

## Configure (`engine.md`)

| Command | The need it serves |
|---|---|
| `wbx var set\|get\|list\|ref` | the per-tenant variable store; secrets are ref-only |

## Develop locally (`engine.md`)

| Command | The need it serves |
|---|---|
| `wbx dev info` | the demo/dev environment at a glance (runtime, health, model key, toolkits) |
| `wbx dev up` | how to start a dev runtime (source mix / prod-parity krunvm) |
| `wbx dev test [args]` | run the runtime test suite (`mix test`) from a source checkout |
| `wbx dev eval [id]` | list toolkit eval suites, or run one server-side |
| `wbx dev ctk` | the CTK review-shell URL served by the connected runtime |
| `wbx version` | print the CLI version |
