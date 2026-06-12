# `wb` — Workbooks CLI (spec)

The single canonical command-line tool for Workbooks. **One Rust crate, two build
targets.** Memory-safe, dependency-free, runs the same logic on a bare OS *and* inside
the runtime's wasm sandbox.

> Supersedes the legacy Elixir escript (`runtime/host/cli.ex`) and the dead npm
> `@work.books/cli` / old `substrates` Rust binary. The escript keeps working until the
> verbs below are migrated; this crate is the canonical home going forward.

## Why Rust (not the escript)

The CLI must run in three places:

1. **Outside the runtime** — a user's laptop / CI, possibly with no Erlang, no Node.
2. **Inside the runtime** — agents call `wb` to author/build/run workbooks.
3. **Inside the wasm sandbox** — agents are sandboxed; the CLI must run there too.

An Elixir escript fails (1) and (3): it drags the whole BEAM and can't run in wasm. A
Rust crate gives **both targets from one source**:

```
cargo build --release                      # → native `wb` (any OS, static, ~fast)
cargo build --release --target wasm32-wasip1   # → wb.wasm (in-sandbox, agents)
```

We do **not** maintain a separate "wasm version." It's the same code, a second target.
CI emits both: the native binary for OS/curl/npm distribution, the `.wasm` for the
runtime to run in-sandbox.

## The discipline that makes both targets work: a capability seam

The CLI itself owns almost no logic — it parses args, talks to the **OQL kernel** (already
Rust, `runtime/kernel/`) for local org ops, and drives the **runtime engine** over RCP for
the heavy verbs. All I/O goes through one trait so the two targets differ only at the edge:

```
trait Io {
    fn http(&self, req: Request) -> Result<Response>;   // talk to the runtime (RCP)
    fn read(&self, path: &str) -> Result<Vec<u8>>;       // filesystem
    fn spawn(&self, cmd: Command) -> Result<Output>;     // docker / krunvm / fly (deploy)
}
```

- **native** (`cfg(not(target_arch = "wasm32"))`): `reqwest` / `std::fs` / `std::process`.
- **wasm** (`cfg(target_arch = "wasm32")`): host imports brokered by the runtime's **Dock**
  (the host-vs-loaded membrane). No raw sockets/process in the sandbox — capabilities are
  granted, not assumed.

Pure logic + kernel calls are target-agnostic and need no seam.

## What the CLI owns vs. delegates

The current escript is 469 lines of near-pure delegation. Same split here:

| Bucket | Verbs | Implementation |
|---|---|---|
| **Kernel (local)** | `query` `tangle` `lint` `bundle` | embed the Rust OQL kernel crate directly (native) / call it in-module (wasm) |
| **Engine (delegate)** | `build` `publish` `library` `pack` `search` `compiler` `mirror` `sign`/`verify` | thin RCP client → the runtime owns the logic. **Never reimplement the engine in Rust.** |
| **Client / local** | `rt` `var` `toolkit list` `desktop` | trivial (HTTP / config) |
| **Bootstrap** | `deploy` | the one verb that must run with **no** runtime up (it brings the runtime up). Orchestrates `docker`/`krunvm`/`fly` + parses `deployment.org`. Lives in `cli/src/deploy/` — see below. |

The rule that keeps this from being over-engineering: **the runtime stays the engine; the
CLI is a flexible handle.** We port the thin shell, not the Elixir logic.

## `deploy` and the `deploy/` folders (classification)

Investigated the root `deploy/` folder. It is **NOT CLI source** — it is two things, both of
which should stay out of this crate:

- **Platform release infra ("just us"):** `deploy/Dockerfile{,.runtime,.compilers}`,
  `fly.toml`, `deploy.sh` — these build *our* ghcr images + deploy *our* production engine,
  and **`runtime-image.yml` CI references them by path** (`deploy/Dockerfile.runtime`,
  `deploy/Dockerfile.compilers`). Moving them breaks CI. They stay at root.
- **Deploy-kit shared assets:** `deploy/deployments/*.org`, `deploy/providers/`,
  `deploy/storage.env.example`, `Dockerfile.runtime` ("the ONE image the deploy-kit runs").
  These are consumed by the deploy-kit; they are infra/templates, not Rust source.

So: **`cli/src/deploy/`** holds only the CLI-side `wb deploy` *command* (Rust — parse
`deployment.org`, orchestrate the provider). The Dockerfiles/fly/configs remain in root
`deploy/` (platform infra + deploy-kit assets). The deploy-kit *engine* logic currently in
`runtime/host/deploy*.ex` is migrated into `cli/src/deploy/` over time (it's the bootstrap
verb that can't depend on a running runtime), or kept runtime-side and driven via RCP.

## Distribution (same CI, NPM_TOKEN + GitHub Release)

One static binary → no Erlang, no Burrito:

- **curl:** `desktop/scripts/install.sh` + the CF worker download the matching binary from a
  GitHub Release.
- **npm (esbuild-style):** a launcher package `@work.books/cli` with per-platform
  `optionalDependencies` (`@work.books/cli-darwin-arm64`, …); npm installs only the matching
  one; a `bin` shim execs it. `npm i -g` works with zero runtime deps.
- **wasm:** `wb.wasm` published for the runtime to run in-sandbox.

## Layout

```
cli/
├── SPEC.md            # this file
├── Cargo.toml         # crate `wb-cli`, bin `wb`
└── src/
    ├── main.rs        # clap parse + dispatch
    ├── io.rs          # the capability seam (native + wasm impls)
    ├── kernel.rs      # embed the OQL kernel (local org ops)
    ├── rcp.rs         # thin runtime client (engine verbs)
    ├── commands.rs    # verb handlers (delegate)
    └── deploy/        # the bootstrap `wb deploy` command (Rust)
        └── mod.rs
```

## Ergonomics: two audiences, one binary (AX + DX)

Audited 2026-06-12. Current facts: every command returns a single `String`
printed once in `main` (one output channel — good); there is **zero**
interactivity (no prompts, no TTY detection — accidentally agent-safe,
deliberately human-poor); errors are anyhow strings with exit code 1 for
everything; no `--json` anywhere; no color; env vars are `WB_*`.

### The prime DX directive

**Human mode is dumb simple: the tool does the work.** Every choice the CLI
can make for the user, it makes — and says what it chose, so trust builds
instead of mystery. Defaults over questions; questions (pickers) only when a
choice is genuinely the user's; never an error where a default + a note
would do; every success teaches the next verb. Learning curve is a bug.
Examples already in force: bare `wbx` = oriented landing, `deploy local` =
scaffold-if-missing-then-apply, `upgrade` detects npm installs and redirects,
`doctor` diagnoses without failing, hints chain build→bundle→sign→deploy.

### The mode model

One switch, three ways to set it, sensible default:

```
auto      stdout is a TTY → human · piped/redirected → agent
--agent   force agent mode (alias: WBX_AGENT=1)
--json    agent mode + single JSON envelope on stdout
```

**Agent mode (AX):** never prompts; no ANSI; stable output shapes; one JSON
envelope `{ok, verb, data, error: {code, hint, retryable}}` under `--json`;
documented exit-code map (0 ok · 2 usage · 3 engine unreachable · 4 not
found · 5 verification failed · 6 conflict · 7 auth rejected); accepts `-` for stdin where a
file is expected; `wbx help --json` emits the verb tree so agents can
introspect the surface instead of parsing help prose.

**Human mode (DX):** color + tables + progress; interactive pickers fill
missing args (e.g. `wbx deploy init` asks place/database when run bare on a
TTY — the same flow agents do with flags); bare `wbx` prints a friendly
where-am-I landing (tenant, engine, current dir state, top verbs) instead of
a usage dump; every success suggests the next verb.

Implementation seam: replace `-> String` with a small `Out` enum
(`Human(String) | Data(serde_json::Value)`); main renders once per mode. The
single-channel design makes this a mechanical refactor, not a rewrite.

### Verb gaps (investigated, prioritized)

P1 — the first ten minutes (launch-blocking):
- `wbx init <name>`  scaffold a workbook source (org + data), `--template`
- `wbx dev [src]`    watch → rebuild → serve preview
- `wbx doctor`       top-level: PATH, version, engine reachability, disco
- `wbx completions <shell>`  clap_complete
P2 — daily ergonomics:
- `wbx open <file>`  open a workbook in the default browser
- `wbx status`       one-screen where-am-I (also the bare-`wbx` landing)
- `wbx upgrade`      self-update from releases (cli.sh logic)
- `WBX_*` env names accepted alongside `WB_*` (docs say WBX_*)
P3 — reach:
- windows release matrix (install.js already expects the asset name)
- stdin pipelines across author/trust verbs

## Import: anything → toolkit (`wbx toolkit import`)

The ecosystem's intake ramp (relates epic wb-rhs): take any existing
agent-capability construct and package it as a toolkit — automatically where
parsing suffices, and where it doesn't, emit the fix-up plan as org TODOs so
an agent (or human) finishes the conversion with instructions in hand.
Philosophy follows the prime DX directive: parse what's parseable, do the
work, and leave a manual — never a shrug.

### Source taxonomy (detect by shape, override with --as)

| kind            | shape detected                                   | maps to                          |
|-----------------|--------------------------------------------------|----------------------------------|
| claude-skill    | SKILL.md (+ references/, scripts/) or skills.sh ref | manifest + skill tree (md→org) |
| markdown        | a single .md file                                | one-skill toolkit (md→org)       |
| folder          | directory of scripts/docs                        | skills from docs, bins from scripts |
| mcp-server      | .mcp.json / mcp manifest (WIRED)                 | skill per server entry; launch synthesized as the audited bin |
| cursor-rules    | .cursor/rules / .cursorrules (WIRED)             | skill tree (guidance-only toolkit) |
| agents-md       | AGENTS.md / CLAUDE.md (WIRED)                    | guidance-only toolkit            |
| openapi-actions | OpenAPI spec, JSON (WIRED; YAML → yq hint)       | skill per operation; HTTP via engine |
| npm-cli         | package.json with bin (WIRED)                    | README → manual; bins carried for the audit + npm-lane plan |
| pip-cli         | pyproject.toml console scripts (WIRED)           | entry stubs synthesized → audit says blocked, plan says rewrite |

### Pipeline (three honest stages)

1. **Parse + scaffold** — detect the kind, translate docs to org (mechanical
   md→org), write `manifest.org` + `skills/` + carried assets. Always
   succeeds for parseable sources; the toolkit may start guidance-only.
2. **Dependency audit (auto-CHECK)** — scan scripts/manifests for
   interpreters, binaries, npm/pip deps, network/fs expectations. Classify
   each against the wasm lanes: `ready` (js/c/zig/rust/go lanes cover it) ·
   `convertible` (known recipe, needs a build) · `blocked` (native-only,
   needs redesign). Emit the report in the manifest; `--json` for agents.
3. **Fix-up plan (the agent manual)** — everything not `ready` becomes org
   TODOs inside the scaffold, each with concrete instructions (which lane,
   which recipe, what to rewrite). `wbx toolkit verify <id>` is the done
   test; auto-CONVERT (engine-backed builds via the compiler lanes) applies
   where the engine is reachable.
