---
name: create-toolkit
description: Author a new Workbooks toolkit — a directory with a `manifest.org` front-door and progressively-loaded `skills/*.org` recipes — per the project authoring standard, then verify the partition. Use when asked to create a toolkit, add a capability, wrap a CLI/API for agents, or expose commands/skills to in-runtime agents. A toolkit is commands-on-PATH + org files, NOT a plugin API or a tool-registry entry — read this BEFORE inventing a new mechanism, because the toolkit format almost always already covers it.
---

# Create a Workbooks toolkit

A toolkit teaches an agent a CLI/API it has never seen. It is **not** a plugin
interface and **not** a new core registry entry: to an agent a toolkit is
**commands on PATH + org-mode skill files read progressively**. Authoring one
means writing two artifacts to a standard so every toolkit in `toolkits/` has the
same shape, depth, and breadth — then verifying the partition holds.

Do the steps in order. Each is a gate; don't skip forward. The bar is **depth**:
a thin, flag-dump skill is a bug, not a shortcut.

## 1. Read the standard FIRST

Do not author from priors. Two docs govern:

- `toolkits/AUTHORING.md` — the operational "exactly what to write" standard:
  the two artifacts, the mandatory skill sections, the task-tier vs leaf-tier
  decision, the depth/breadth bar, the authoring checklist.
- `runtime/docs/TOOLKITS-V3.md` — the runtime contract: the three nouns
  (capability / command / toolkit), the `#+EXEC` shapes, `#+TRUST`, discovery via
  `(tags :toolkit:)`, the security model (the toolkits root is an **untrusted,
  writable** dir — reads open, execution default-deny + sandboxed).

The gold-standard exemplar is `toolkits/ffmpeg/` (manifest + ~20 deep skills).
When in doubt, open `toolkits/ffmpeg/skills/image-resize.org` and match its shape.
For the full anatomy and the six mandatory sections see
`references/manifest-anatomy.md` and `references/skill-sections.md`.

## 2. Scaffold via the forge

Lay the skeleton down with the `toolkit-forge` toolkit (or the `/forge-toolkit`
entry where present) rather than hand-creating files — it produces `manifest.org`
+ `skills/` in the standard arrangement and drives RESEARCH → DESIGN → AUTHOR →
VERIFY. The DESIGN phase emits the skill map (skill list + per-skill need +
groupings); the AUTHOR phase realizes it; VERIFY asserts the partition.

If forge is unavailable, create `toolkits/<slug>/manifest.org` and
`toolkits/<slug>/skills/` by hand to the same standard — `slug` is whitespace-free
and equals the dir name and the manifest `:ID:`.

## 3. Write `manifest.org` — the index, not the manual

The front door the runtime reads to build the auto-injected TOOLKITS index. It
**indexes skills by NEED; it never duplicates a skill body.** Frontmatter order
matters (match ffmpeg). The body is one `:toolkit:`-tagged headline + a
skill-index table where **every `skills/*.org` appears exactly once**, keyed by
the agent's need (the "Use when" column is the router, not a restatement of the
skill name). The drawer's `:ID:`/`:CLI_BIN:`/`:STATUS:` MUST equal the matching
`#+` keywords — verify checks this. Full template in
`references/manifest-anatomy.md`.

## 4. Write `skills/overview.org` + the leaf skills

`overview.org` is mandatory — first-contact: what the toolkit covers, the one
cross-cutting gotcha, a pointer into the index. Then one file per task/verb, each
carrying the **six mandatory sections** (When to use · mental model · workflow ·
common pitfalls · verification checklist · see-also) and the full header. Target
150–300 body lines; below ~120, you didn't go deep. Progressive disclosure is the
point: the manifest is the INDEX, skills are read on demand. See-also links cross-
link siblings by INTENT and **must resolve**. See `references/skill-sections.md`.

## 5. Add EXEC shapes as the surface needs

The manifest `#+EXEC` selects HOW the artifact is invoked:
`command` (stdio CLI→WASM, the default) · `component` (3rd-party WASM, set
`#+TRUST: third-party`) · `task` (a runnable multi-verb recipe, the default entry
for a DEEP CLI) · `federation` · `posix` · `kernel` (bytes→bytes hot loop). For a
**deep** CLI (`#+FLOW` chains ≥3 verbs, ≥6 verb groups, or a verb nests ≥2 levels)
ship ≥1 **task recipe** per common need — a `:role task` bash block taking the
user's NOUN, surfaced in a Task index ABOVE the leaf index. A `:role task` block
is run via `wbx toolkit run <id> <task> -- <args>`. Shallow CLI ⇒ the leaf IS the
task.

## 6. Verify the partition

Never await CI. Run, at the tightest tier first:

```
wbx toolkit verify <id>   # partition: skills indexed once, see-also resolves, overview present, drawer==keywords
wbx toolkit eval <id>     # does it behave? runs evals/*.org (needs WB_TOOLKIT_EXEC=1)
wbx toolkit build <id>    # declarative auto-wrap of #+BUILD_SRC → register command
wbx toolkit run <id> <task> -- <args>   # exercise a :role task recipe
wbx toolkit sign <id>     # sign with the tenant did:key to ship
```

Re-read the files you wrote; confirm `verify` passes (this is the done-gate). For
the assertions verify makes and how eval tiers work, see `references/verify-eval.md`.

## Done means

- `manifest.org` complete; drawer matches `#+` keywords.
- Every `skills/*.org` indexed exactly once; `overview.org` present and useful.
- Deep CLI ⇒ ≥1 task recipe per common need; shallow ⇒ leaf is the task.
- Every skill has the six sections, is DEEP (mental model + 4+ pitfalls +
  checklist), not a flag dump.
- All see-also links resolve; org parses; every file < 800 LOC.
- `wbx toolkit verify <id>` passes; recipes verified where the CLI is runnable
  (un-verifiable ones flagged `#+STATUS: experimental` and logged).
