# `work` verbs this skill uses — the contract

Every command below is a **real** verb in the canonical `work` CLI (the Elixir
escript; dispatch in `runtime/host/cli.ex`). If a verb isn't here, it's not in
this skill. The binary is `work` — never `wb`/`wbx` (those are retired).

## Authoring + structure

| Verb | Does |
|---|---|
| `work content check [dir]` | validate a workbook folder (HTML-first; defaults to `.`) |
| `work structure <src>` | list the `work-*` elements (tagname + id/title) — the outline |

## Compiler lane (`<work-src>` → WASM, via the Dock)

| Verb | Does |
|---|---|
| `work compiler` / `work compiler list` | list languages the Dock can build |
| `work compiler build <lang>` | build the in-WASM compiler for a language |
| `work compiler run <lang> <file> [args…]` | compile + run a source file to WASM |

## Kit (toolkit) commands — promote inline source into a reusable command

| Verb | Does |
|---|---|
| `work kit` / `work kit list` | list installed kits |
| `work kit show <id> [skill]` | show a kit (or one of its skills) |
| `work kit build <id> [which]` | build a kit's `work-src` blocks |
| `work kit build-inline <name> <lang> <file>` | build one inline source block |
| `work kit promote <name> <lang> <file>` | promote an inline block to a kit command |
| `work kit run <id> <task> [args…]` | run a kit task |
| `work kit verify <id>` | verify a kit |

> `work toolkit …` is an alias for `work kit …` (same dispatch).

## Bundle / unbundle

| Verb | Does |
|---|---|
| `work bundle <dir> <out> [flags]` | weave a folder tree → one self-contained `.html` |
| `work unbundle <in.html> <dir>` | recover the source tree (lossless round-trip) |

## Dev loop

| Verb | Does |
|---|---|
| `work dev info` | demo-env dashboard: runtime target + `/health`, model key, toolkits root |
| `work dev up` | bring the demo env up |
| `work dev test [args…]` | run the suite (`= mix test`) |

## Deploy (the user's runtime-run tool — never platform release)

| Verb | Does |
|---|---|
| `work deploy local` | zero-config local run (same OCI image as prod, krunvm) |
| `work deploy init [preset]` | scaffold `./deployment.html` (preset: `local`\|`cloud`) |
| `work deploy validate [file]` | coherence-check `deployment.html` (no apply) |
| `work deploy apply [file]` | reconcile the declared deployment |
| `work deploy status [file]` | current deployment status |
| `work deploy verify [file]` | verify a running deployment |
| `work deploy logs [file]` | stream logs |
| `work deploy down [file]` | tear the deployment down |
| `work deploy doctor` | environment preflight |

Add `--json` to any `work deploy` verb for machine-readable output (exit 0 ok /
non-zero fail).

## Publish (render a workbook → live URL)

| Verb | Does |
|---|---|
| `work publish init` | scaffold `./publish.html` |
| `work publish validate [file]` | coherence-check it (no render, no deploy) |
| `work publish apply <file.html>` | render + ship → prints the live URL |
| `work publish site [dir]` | render a multi-page site → deploy |
