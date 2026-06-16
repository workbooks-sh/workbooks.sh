---
name: getting-started
description: Onboard an agent or developer to a Workbooks project from zero. Read FIRST in any repo that contains a `skills/` folder or a `work` CLI. Covers the non-interactive first-run setup — installing the work CLI, pointing at a runtime, and loading the rest of the Workbooks skills. Use when you land in an unfamiliar Workbooks repo, when asked to "set up" / "get started" / "onboard", or before invoking create-workbook / create-toolkit.
---

# Getting started on a Workbooks project

You just landed in a repo that looks like it builds on Workbooks. Don't guess at
the mechanism — Workbooks almost always already provides one. This skill takes
you from zero to oriented, non-interactively, in six steps. Do them in order;
each one cheaply rules out work the next step would otherwise duplicate.

> First principle: **viewing or authoring a workbook needs NO runtime.** Never
> block onboarding on standing a server up. A runtime is only needed when the
> task actually computes (agents, sandboxed builds). Stay un-gated.

## 1. Detect what kind of repo this is

Classify before acting. Run the cheap probes and match against the table in
`references/repo-shapes.md`:

```sh
ls skills toolkits runtime 2>/dev/null     # which trees exist?
command -v wb && wb --version || echo "install needed"
```

- `skills/` present → a Workbooks project; this skill applies.
- `runtime/` (Elixir `mix.exs`, `runtime/host/`) → the **platform repo**.
- `toolkits/` but no `runtime/` → a **consumer/tenant project**.
- A self-building site (e.g. an `app/` with an org BOARD) → a **tenant artifact**.

The classification decides which task ledger you use (step 5) and which sibling
skill you hand off to (step 6).

## 2. Install the `work` CLI — non-interactively

If `work` is absent, build the canonical escript from this repo's runtime, or use
a published path. **Always pass non-interactive flags** (`-y`,
`BatchMode=yes`, `HOMEBREW_NO_AUTO_UPDATE=1`) — an aliased `-i` prompt will hang
an agent shell forever.

```sh
cd runtime && mix escript.build      # canonical: runtime/host/cli.ex → ./wb
```

Full build + install paths (and the `workbook` standalone-artifact CLI, which is
a separate tool) are in `references/cli-bootstrap.md`. There is exactly **one**
canonical `work` — the Elixir escript from this repo. Ignore any legacy Rust `work`
or npm `@work.books/cli`; both are dead.

## 3. Load the sibling skills

Read the frontmatter of every `skills/*/SKILL.md` so you know which
create/edit-* skills exist before inventing anything:

```sh
for f in skills/*/SKILL.md; do echo "== $f"; sed -n '1,4p' "$f"; done
```

Then read `skills/workbooks-system/SKILL.md` end-to-end — it defines the
platform concepts (workbook, runtime, toolkit, workflow, Dock, HOST vs LOADED,
the WASM-only rule). Read it **before** reaching for any mechanism; the platform
usually already provides one.

## 4. Locate a runtime — only if the task needs compute

```sh
work dev info       # demo dashboard: runtime target + /health, model key, toolkits root
```

If there's no runtime and the task genuinely needs one, `work deploy local` stands
one up (krunvm, same OCI image as prod — **users only**, never a platform-release
path). If the task is just viewing or authoring an artifact, skip this entirely.

## 5. Confirm the task ledger

Read the `working-with-tasks` skill and pick the **right** ledger — do not
conflate them:

- **Platform/engine repo** → `bd ready` (beads; local Dolt, never in git).
- **Tenant artifact** → the in-repo org board (`:TASK:` / state front-matter).

## 6. Hand off

State which skill to invoke next based on intent:

| Intent | Next skill |
|---|---|
| fuzzy idea, needs scoping first | `workbooks` (planning) |
| build a new HTML workbook | `create-workbook` |
| change an existing workbook | `edit-workbook` |
| author a capability/toolkit | `create-toolkit` |
| change a toolkit | `edit-toolkit` |
| engine/runtime work | `create-runtime` / `edit-runtime` |
| discover/claim board work | `working-with-tasks` |

## References

- `references/cli-bootstrap.md` — escript build + install paths, `work` vs `workbook`.
- `references/repo-shapes.md` — consumer vs platform vs tenant detection table.
