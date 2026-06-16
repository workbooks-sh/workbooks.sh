---
name: edit-toolkit
description: Modify an existing Workbooks toolkit — edit a skill recipe, add a task, fix the manifest index, fix a broken see-also link — keeping the partition valid. Use when asked to change / fix / extend / update a toolkit or one of its skills. ALWAYS re-run `work toolkit verify` after, because the verify partition (every skill indexed once, see-also resolves, overview present, drawer matches keywords) is the toolkit's invariant and the smallest edit can break it.
---

# Edit a Workbooks toolkit

A toolkit is a `manifest.org` front-door + `skills/*.org` recipes read
progressively. Editing one means making the **smallest change** while keeping the
**partition** valid — every skill indexed exactly once, every see-also link
resolving, `overview.org` present, the manifest drawer matching the `#+`
keywords. The done-gate is `work toolkit verify <id>` passing, same as authoring.

Do the steps in order. Don't hand-edit and assume it's fine — verify, always.

## 1. Inspect

Find what's there before you touch it:

```
work toolkit list                 # every toolkit: id · status · tagline
work toolkit show <id>            # the manifest front door + skill index
work toolkit show <id> <skill>    # one skill body (prefixed with a #+CAPTION TOC)
work toolkit search <query>       # substring search across all skills
```

Read the relevant skill before changing it — that's tier 2 of progressive
disclosure. For what a well-formed skill/manifest looks like (the six mandatory
sections, the index rules), see `references/skill-sections.md`.

## 2. Locate the edit

Map the requested change to the right artifact and tier:

- a recipe / gotcha / verify-step change → the leaf `skills/<slug>.org`.
- a new common multi-verb need on a DEEP CLI → a new **task** recipe (`:role
  task` block), surfaced in the Task index ABOVE the leaf index.
- a new leaf need → a new `skills/<slug>.org`.
- an index/router/grouping/link fix → `manifest.org`.

Respect **task-tier vs leaf-tier**: a deep CLI is reached for at the task tier
(one noun in, the recipe owns the fan-out); the leaves are the long tail beneath.
Don't surface a deep CLI leaf-first.

## 3. Edit — smallest change

Apply the minimal change. Keep the skill DEEP — don't degrade a recipe into a
flag dump. **If you add a skill**, you have two obligations that verify checks:

1. Register it in the manifest index table **exactly once**, keyed by the agent's
   NEED (not a restatement of the name); the trigger must not collide with an
   existing row (the triggers must partition the surface).
2. Add see-also `[[file:other.org][label]]` links from and to adjacent siblings —
   and make sure every link target exists.

A new skill must carry the full header + the six mandatory sections; see
`references/skill-sections.md`.

## 4. Verify the partition (must pass)

Never await CI. Run at the tightest tier first:

```
work toolkit verify <id>   # MUST pass: indexed-once, see-also resolves, overview present, drawer==keywords, #+EXEC satisfiable
WB_TOOLKIT_EXEC=1 work toolkit eval <id>   # does it still behave? runs evals/*.org
```

`verify` is the invariant gate — re-run it after every edit, even a one-line one.
For exactly what verify asserts and how eval tiers work, see
`references/verify-eval.md`.

## 5. Build / run regression

If the edit touches the command or a task recipe, exercise it:

```
work toolkit build <id>                 # re-wrap #+BUILD_SRC → register command
work toolkit run <id> <task> -- <args>  # run the :role task block (needs WB_TOOLKIT_EXEC=1)
```

## 6. Sign + ship

```
work toolkit sign <id>    # re-sign with the tenant did:key
```

Live-confirm the change — don't trust the commit alone.

## Done means

- Smallest change applied; skill stays DEEP (not degraded to a flag dump).
- Added skills: indexed exactly once by need (no trigger collision); full header +
  six sections; see-also links from/to siblings all resolve.
- `work toolkit verify <id>` passes; eval still green where runnable.
- Command/task regression exercised if touched; re-signed; live-confirmed.
