# Verify · eval · build · run — the `wbx toolkit` learn-and-check surface

These run **in-process** when an agent calls `wbx` locally over the on-disk
toolkits root, or **server-side** over `/rcp/toolkit/*` from the shipped escript
(it can't load the NIFs — same verbs, same output). Discovery root:
`$WB_TOOLKITS_ROOT` (if an existing dir), else `toolkits/` or `../toolkits/`. The
root is **untrusted, writable**: read surfaces are open (path-contained);
execution surfaces are default-deny. Source: `skills/workbooks-system/references/cli/toolkit.md`.

## verify — `wbx toolkit verify <id>` (the done-gate)

Is this toolkit well-formed and runnable here? Asserts the **partition**:

- manifest present and parseable; drawer `:ID:`/`:CLI_BIN:`/`:STATUS:` == the `#+`
  keywords.
- every `skills/*.org` indexed in the table exactly once.
- `overview.org` present.
- every `[[file:…]]` see-also link resolves.
- `#+EXEC` satisfiability.
- runs every `:role pre` block (ONLY when `WB_TOOLKIT_EXEC=1`, under the sandbox;
  unset ⇒ pre blocks reported SKIPPED).

`verify` passing is what "done" means for structure.

## eval — `wbx toolkit eval <id>`

Does the toolkit actually behave? Runs its `evals/*.org` suite. Needs
`WB_TOOLKIT_EXEC=1` (from the escript routes to `/rcp/toolkit/eval`).

- **Tier 1** — deterministic `:role eval` block + assert `#+EXPECT:`.
- **Tier 2** — an LLM judge over a `:TASK:` (non-deterministic).
- Result per case: `pass | fail | skip` with a label.

## build — `wbx toolkit build <id> [which]`

Declarative auto-wrap — build the toolkit's `#+BUILD_SRC` and register its
command, no hand-wiring. By descriptor (`#+EXEC:` + `#+BUILD_SRC:`):

- `command` + `crate:<name>` → build the crate → register the command.
- `command` + `path:<dir>` → build the dir → register.
- `posix` → reports whether the native binary is already on PATH (nothing to build).
- `task` / `federation` → no CLI binary to build.
- `kernel` → a bytes→bytes reactor (today `#+BUILD_LANG: c` + `path:<dir>` .c source).
- Failure: `no #+BUILD_SRC declared`; `git+<url> not yet supported (use
  crate:/path:)`; refusal to shadow a reserved built-in name (jq/grep/upper).

## run — `wbx toolkit run <id> <task> -- <args…>`

Execute a skill's `:role task` block with positional args (`$1 $2 …`). Gated by
`WB_TOOLKIT_EXEC` + sandbox. Failure: `no :role task block in <id>/<task>`. This
is how a not-CLI-we-own task ships runnable — the executed bytes ARE the
documented block (no doc/script drift).

## sign — `wbx toolkit sign <id>`

Sign the toolkit with the tenant's did:key — the third-party-trust rail — to ship.

## Build order when authoring

1. `wbx toolkit verify <id>` — structure first (fast, no exec needed for the
   non-`:role` checks).
2. `WB_TOOLKIT_EXEC=1 wbx toolkit eval <id>` — behavior.
3. `wbx toolkit build <id>` then `wbx toolkit run <id> <task> -- <args>` — exercise
   the command/task.
4. `wbx toolkit sign <id>` — ship. Live-confirm; never trust the commit alone.
