# Toolkit commands — `wbx toolkit`, `wb-rt compiler`, `wb isolation`

A toolkit teaches an agent a CLI it has never seen: a directory with a
`manifest.org` (the `:toolkit:` front door) and `skills/*.org` recipes read
progressively. For the authoring model see `../toolkit.md`; for the org surfaces
see `../org-specs.md`.

**Where these run:** in-process (an agent calling `wbx`) they run locally over the
on-disk toolkits root. From the shipped escript they run **server-side** over
`/rcp/toolkit/*` (the escript can't load the NIFs) — same verbs, same output.

**Discovery root:** `$WB_TOOLKITS_ROOT` (only if it's an existing dir), else
`toolkits/` or `../toolkits/`. The root is an **untrusted, writable** directory:
read surfaces are open (path-contained); execution surfaces are default-deny.

TOC: list/show/search · verify · eval · build · build-inline/promote · run · sign
· compiler · isolation

## Discover — `wbx toolkit list | show | search`

- **`list`** — every toolkit under the root: `id · status · tagline`.
- **`show <id>`** — the manifest front door + the skill index.
- **`show <id> <skill>`** — one skill body, prefixed with a `#+CAPTION` table of
  contents. **Read the relevant skill before using a toolkit** — this is tier 2
  of progressive disclosure.
- **`search <query>`** — substring search across all skills.
- **Failure:** `no such toolkit: <id>` / `no such skill: <id>/<slug>`.

## Verify — `wbx toolkit verify <id>`

- **Need:** is this toolkit well-formed and runnable here?
- **Action:** structural checks (manifest present, parseable), `#+EXEC`
  satisfiability, and runs every `:role pre` block in its skills.
- **Security:** `:role` blocks are arbitrary host bash — they run ONLY when
  `WB_TOOLKIT_EXEC=1`, and even then under `Workbooks.Sandbox` (network-denied,
  fs-confined, ulimit-capped). Unset → pre blocks are reported **SKIPPED**.

## Eval — `wbx toolkit eval <id>`

- **Need:** does the toolkit actually behave? Runs its `evals/*.org` suite.
- **Action:** Tier 1 — deterministic `:role eval` block + assert `#+EXPECT:`.
  Tier 2 — an LLM judge over a `:TASK:` (non-deterministic). Needs
  `WB_TOOLKIT_EXEC=1`; from the escript it routes to `/rcp/toolkit/eval`.
- **Result per case:** `pass | fail | skip` with a label.

## Build — `wbx toolkit build <id> [which]`

- **Need:** declarative auto-wrap — build a toolkit's `#+BUILD_SRC` and register
  its command, no hand-wiring.
- **Action by descriptor** (`#+EXEC:` + `#+BUILD_SRC:` in the manifest):
  - `command` + `crate:<name>` → build the crate → register the command.
  - `command` + `path:<dir>` → build the dir → register.
  - `posix` → reports whether the native binary is already on PATH (nothing to build).
  - `task` / `federation` → no CLI binary to build.
  - `kernel` → a bytes→bytes reactor (today only `#+BUILD_LANG: c` with a
    `path:<dir>` .c source).
- **Failure:** `no #+BUILD_SRC declared`; `git+<url> not yet supported (use
  crate:/path:)`; refusal to shadow a reserved built-in name (jq/grep/upper).

## Self-author — `wbx toolkit build-inline`, `wbx toolkit promote`

- **`build-inline <name> <lang> <file>`** — build a single source file
  (`rust|c|zig|js|ts|go`) → register it as a **session** command. The agent
  writing its own tool.
- **`promote <name> <lang> <file>`** — promote a session command to a **durable**
  workspace toolkit: writes a toolkit dir under the root with a `manifest.org`
  (`#+EXEC: command`, `#+TRUST: first-party`, `#+BUILD_SRC: path:…`) so it's
  source-owned and packable.

## Run a task — `wbx toolkit run <id> <task> -- <args…>`

- **Need:** execute a skill's `:role task` block with positional arguments.
- **Action:** extracts the named skill's `:role task` bash block and runs it with
  the args after `--`. Gated by `WB_TOOLKIT_EXEC` + sandbox like other execution.
- **Failure:** `no :role task block in <id>/<task>`.

## Sign — `wbx toolkit sign <id>`

Sign the toolkit with the tenant's did:key (the third-party-trust rail).

## Compiler lane — `wb-rt compiler`

The in-WASM compiler toolchain (zero native execution; compilers run in the sandbox).

- **`list`** — installed compilers.
- **`build <lang>`** — build a language compiler → WASM, register its command.
- **`run <lang> <file> [argv…]`** — compile + run a source file in the sandbox.
- **Failure:** `compiler build FAILED for <lang>: …` / `compile/run FAILED …`.

## `wb isolation`

Print the isolation-tier ladder — the `(width, tier)` depth knob for how
toolkit/agent instances are isolated (wasm-instance → OS-process → peer BEAM node
→ container).
