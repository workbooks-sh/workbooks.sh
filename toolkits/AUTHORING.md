# Toolkit authoring — the depth/breadth standard every toolkit follows

Date: 2026-06-05
Epic: wb-skv2
Related: ../runtime/docs/TOOLKITS-V3.md (authoritative, clean-room), ../runtime/docs/TOOLKITS-PLAN.md, ../runtime/docs/TOOLKIT-SKILLS-V2.md, ../runtime/docs/TOOLKIT-DISCOVERY.md

> NOTE (2026-06-07): the three RELATED design docs were restored from the archive
> this day (each carries a clean-room reconciliation banner). For the AUTHORITATIVE
> clean-room shape — per-toolkit EXEC mode, the `wb toolkit` surface, telemetry/
> VFS integration — read ../runtime/docs/TOOLKITS-V3.md first. This file remains
> the operational "exactly what to write" standard; V3 owns the runtime contract.

## Why this doc

The toolkit *format*, *discovery model*, and *depth philosophy*
already have homes:

- `../runtime/docs/TOOLKITS-PLAN.md` — the directory shape,
  distribution tiers, the auto-injected TOOLKITS index, the five
  toolkit-format claims.
- `../runtime/docs/TOOLKIT-SKILLS-V2.md` — the depth bar (thin
  skills are a bug), the mandatory skill sections, thin-vs-thick,
  the `references/` sub-dir pattern, what the format actually buys us.
- `../runtime/docs/TOOLKIT-DISCOVERY.md` — the toolkit-tagged
  node + `TOOLKITS` resolution contract at runtime.

This doc does NOT restate them. It is the **operational standard** an
author (human OR the `forge-toolkit` workflow) follows so that every
toolkit in `toolkits/` is consistent in **depth and breadth**. Read the
three docs above for the *why*; read this for *exactly what to write*.

The exemplar is `ffmpeg/` (manifest v0.3.0 + 20 deep skills). When in
doubt, open `ffmpeg/skills/image-resize.md` and `ffmpeg/skills/lossy-tradeoffs.md`
and match their shape.

## The two artifacts

### `manifest.html` — the index, not the manual

One per toolkit at `toolkits/<name>/manifest.html`. It is the **front
door** the SessionRunner reads to build the auto-injected TOOLKITS
index, and the first thing an author/agent reads to decide if this
toolkit is the right one. It indexes the skills by NEED; it never
duplicates a skill's body.

The manifest is a single `<work-toolkit>` element whose attributes carry
the toolkit metadata (order doesn't matter; match ffmpeg):

```html
<work-toolkit
  id="<slug>"                  <!-- whitespace-free; == dir name -->
  version="<semver of THIS wrapper, not the underlying CLI>"
  cli="<executable on PATH, e.g. ffmpeg / git / pdftk>"
  cli-version-range="<range the skills are tested against, e.g. >=6.0>"
  status="stable | experimental | deprecated"
  tagline="<one sentence — when to reach for this toolkit>"
  requires="<space-separated extra CLIs, e.g. node>=20 npm>">
```

Optional, used by richer toolkits (see brandnana): `kind` (when
not a plain `cli`), `env-keys` + `env-note` (creds the CLI
reads), `flow` (the one-line happy-path pipeline). Add them only
when they carry real information.

The body is a `<work-doc>` child holding the front-door prose — a short
description of what this wraps, the WHY (what an agent gets wrong from
training priors / from skimming `--help`), where NOT to use it / what to
reach for instead — plus a skill-index table:

```
| Skill            | Use when                                    |
|------------------|---------------------------------------------|
| `overview`       | First contact — what this toolkit covers    |
| `<slug>`         | <the NEED that routes here, one line>       |
| ...              | ...                                         |
```

Rules:
- Every skill file in `skills/` appears in the table exactly once.
  The table IS the progressive-disclosure map (see "Progressive
  disclosure").
- The "Use when" column is phrased as a **need/trigger**, not a
  restatement of the skill name. "Cut a slice — first N sec" beats
  "trim a video".
- Group with `— GROUP —` rows when the surface splits cleanly
  (ffmpeg uses `— IMAGE —` / `— VIDEO —`). Don't invent groups
  for <6 skills.
- The `id` / `cli` / `status` attributes MUST equal the toolkit's real
  identity. The forge VERIFY phase checks this.

### `skills/<slug>.md` — a deep, verified recipe

One file per task/verb. **Depth is the bar.** A skill is not a
man-page paraphrase — it is the recipe + the GOTCHAS + the WHY + a
verification checklist, empirically verified where the tool is
runnable. Target 150-300 body lines (TOOLKIT-SKILLS-V2 §Success);
below ~120 lines, ask whether you actually went deep.

Canonical front-matter (every key load-bearing), as a small list at the
top of the file:

- **Title**: `<toolkit> — <task, with the key gotcha hinted>`
- **Toolkit**: `<toolkit>` (== manifest id)
- **Skill**: `<slug>` (== filename without extension)
- **Version**: `<skill semver, independent of toolkit version>`
- **Description**: Use when `<trigger>`. `<one-line behavior + the knobs covered>`.
- **Tags**: `<space-separated lookup tags — verbs + nouns the agent searches>`
- **Status**: stable | experimental | deprecated

Mandatory sections, in this order (lifted from the ffmpeg skills):

1. **When to use this** — with a small property list carrying the
   runtime-honored flags, then a trigger paragraph AND an explicit
   "NOT for: `<x>` (see [other](other.md))" line.

   ```
   When to use this
     NETWORK:     no            # yes ⇒ skipped offline, declares cost
     DESTRUCTIVE: no            # yes ⇒ agent confirms before running
     REQUIRES:    <extra CLIs>  # optional; pre-flight at load
     OS:          macos linux   # optional; skipped on mismatch
     COST:        free          # free | paid; gates live-API skills

     <1 paragraph: the exact situation that routes here.>
     NOT for: <adjacent need> ([adjacent](adjacent.md)).
   ```

2. **The mental model** (or a named concept section) — the WHY
   before the HOW. The table/paragraph that makes the recipes make
   sense (ffmpeg: the `scale=W:H` with `-1/-2` table). Skip only for
   genuinely single-step skills.

3. **Workflow** — numbered/sub-headed steps, each a captioned code
   block. Wrap the recipe in verification blocks:

   ````
   ## <what this block does — the TOC entry>
   ```bash :role pre
   <precondition check — input exists? tool the right version?>
   ```

   ## <the actual recipe>
   ```bash
   <the command(s)>
   ```

   ## <confirm it worked>
   ```bash :role post :path <output>
   <postcondition check — output exists / is valid>
   ```
   ````

   Every code block gets a `##` caption (it is the surfaced TOC).
   `:role pre` runs before the agent suggests the recipe; `:role
   post` validates after. `$1` in a role block is the path the
   runtime passes.

4. **Common pitfalls** — numbered, each *mistake → why → fix*. This
   is the highest-value section: the things that look right after a
   `--help` skim but bite. Aim for 4-6 real ones, empirically found.

5. **Verification checklist** — `- [ ]` boxes the agent ticks after
   running. Concrete, checkable (run `ffprobe`, `grep`, `file`), not
   vibes.

6. **See also** — `[label](other.md)` links to sibling
   skills by INTENT ("when you start from someone else's file"),
   plus the authoritative man-page escape hatch (`ffmpeg -h
   filter=scale`). Every link target MUST exist (forge VERIFY checks).

Thick skills (large sub-surface): use `skills/<slug>/SKILL.md` +
`skills/<slug>/references/<topic>.md` per TOOLKIT-SKILLS-V2 §"What
the skill trees should look like". The SKILL.md is the front door
and points at references by file path. Default to a flat single file;
reach for the dir only when one skill genuinely needs deep-dives.

## Task recipes — the task tier (the default entry point for DEEP CLIs)

A deep/nested CLI (many verbs × subcommands × args — e.g. `brandnana social`:
25+ platforms × kinds × handle) must NOT be surfaced leaf-first. An agent given
only the leaves has to (1) discover the structure, (2) compose each invocation,
(3) orchestrate the sequence — three jobs that are NOT its task. A real run wasted
~14 min with the scout running `strings` on the binary to reverse-engineer the
social commands (wb-yr2r). The fix is a THIRD tier ABOVE the leaves.

### The three tiers (the agent reaches for the HIGHEST that fits)
1. **MANIFEST** — the auto-injected catalog row. For a deep CLI it carries `flow`
   (the one-line happy path) and a TASK index ABOVE the leaf index.
2. **TASK tier** — one RUNNABLE recipe per common multi-verb NEED, invoked as a
   SINGLE call whose input is the user's NOUN (`<domain>`), not a verb chain. The
   task OWNS the dirty work: handle/dep discovery, the fan-out, the lane writes,
   the safe-writes. THIS is the default the agent reaches for.
3. **LEAF tier** — the full per-verb reference, read ONLY when extending a task or
   doing something off the happy path.

### "Wrap the SEQUENCE, not the verb"
A task's unit is a NEED ("harvest this brand's social presence") spanning many
verbs — not one verb with nicer docs. Enumerate the cross-verb NEEDS first; ship a
task recipe for each; the leaves are the long tail beneath them.

### How a task is made RUNNABLE (the engine never executes markup)
The runtime executes NO markup directly; skills are read and the agent
re-composes their bash. So a task ships as a runnable recipe, chosen by OWNERSHIP:
- **CLI we own** (e.g. brandnana — bun `build --compile`): add the task as an
  UPSTREAM CLI VERB (`brandnana harvest social <domain>`) wrapping the internal
  sequence server-side. Most robust — one noun in, zero agent jq/python/fan-out.
- **CLI we don't own**: ship the recipe as a `:role task`-tagged ```` ```bash ````
  block (positional `$1 $2` args) and run it with `wb toolkit run <toolkit> <task>
  -- <args>` (extracts + runs the block via the existing `extract_role_blocks` /
  `run_bash_snippet`). The executed bytes ARE the documented block — no doc/script
  drift, no on-PATH `.sh` dump, no emacs in the image.

### The depth heuristic (when a task tier is MANDATORY)
A CLI is "deep" — and MUST ship >=1 task recipe per common need — when ANY holds:
the manifest `flow` chains >=3 verbs; the surface has >=6 verb groups; or a verb
nests >=2 levels (`social <platform> <kind>`). Shallow CLIs (git, an ffmpeg per-op)
need no task tier — there the leaf IS the task.

## The depth/breadth bar (the consistency contract)

Every forged toolkit MUST clear this, or it is not done:

- **Deep, not shallow.** recipe + the GOTCHAS + the WHY + a checklist +
  see-also. A skill that is a flag list is a failure. (TOOLKIT-SKILLS-V2:
  "format is fine, skills are thin" was the bug v2 fixes — don't
  reintroduce it.)
- **Empirically verified where runnable.** If `cli` installs in the
  forge environment, the author RUNS the headline recipes (on a tiny
  fixture) and the `:role pre/post` blocks, and fixes what fails. If
  the tool can't be installed, the author says so explicitly in the
  run log and marks the skill `status: experimental` until a human
  verifies.
- **Consistent, NOT deterministic.** Two authors (or two forge runs)
  targeting the same tool produce skills of the same SHAPE, DEPTH, and
  section set — not byte-identical prose. The standard fixes the
  skeleton and the bar; the content is the author's judgment. Don't
  template-fill; write real recipes for real needs.
- **Breadth = the common surface, not the whole man page.** Cover the
  tasks an agent actually reaches for + the gotchas that bite, plus an
  `overview.md`. Leave exhaustive flag enumeration to `--help`
  (linked from See also). ffmpeg ships 20 skills because the surface
  is huge; a focused CLI may ship 5. Match the surface, not a quota.
- **General + reusable.** Toolkits are project-agnostic (the ffmpeg
  toolkit serves any project). Write correct, general usage; never
  bake one project's paths/assumptions into a toolkit skill.
- **Under budget.** Each file < 800 LOC (repo hard cap); a single skill
  over ~400 lines is a signal to split into a thick `SKILL.md +
  references/`.

## Progressive disclosure — how it is standardized

Progressive disclosure is the whole point: the manifest is the INDEX,
the skills are read on demand via `cat`. Two layers (TOOLKIT-SKILLS-V2
§"tool_search pattern"): BETWEEN skills (pick one skill per task) and
WITHIN a thick skill (SKILL.md → references on demand).

The standard for deciding WHICH skills exist and how the manifest
indexes them:

1. **Enumerate the needs, not the flags.** From studying the real
   CLI/API surface (the forge RESEARCH phase), list the distinct
   *tasks an agent will want to do*. One need that has its own gotchas
   and its own verify = one skill. Merge needs that share a recipe;
   split a need that branches into materially different recipes
   (ffmpeg split "scale image" from "scale video" because the
   even-dim/SAR gotchas differ).

2. **Always ship `overview.md`.** First-contact: what the toolkit
   covers, the one cross-cutting gotcha (ffmpeg: -i/filter arg order),
   and a pointer into the index. It is the agent's "is this the right
   toolkit?" stop.

3. **Index by NEED in the manifest table.** The "Use when" column is the
   router. An agent scans the table, matches its intent to a row,
   `cat`s that one skill. So each row's trigger must be the **need in
   the agent's words**, and the set of triggers must PARTITION the
   surface (no two skills claim the same need; no common need
   unowned). Group rows when the surface splits (`— IMAGE —`).

4. **Cross-link siblings in See also.** Adjacent needs link to each
   other so the agent that landed one row away can hop. The links
   form the skill graph; they must resolve.

The forge DESIGN phase produces exactly this map (skill list + the
per-skill need + groupings) as structured output, and the AUTHOR
phase realizes it. The VERIFY phase asserts the partition holds:
every skill indexed once, every See-also link resolves, `overview`
present.

## Authoring checklist (what "done" means)

- [ ] `manifest.html` present, `<work-toolkit>` attributes complete, `id`/`cli`/`status`
      match the toolkit's real identity.
- [ ] Skill index table lists every `skills/*.md` exactly once,
      keyed by need.
- [ ] `overview.md` exists and is first-contact useful.
- [ ] DEEP CLI (per the depth heuristic) ⇒ ships >=1 TASK recipe per common
      multi-verb need, each taking the user's NOUN (not a verb chain), surfaced
      in a Task index ABOVE the leaf index. Shallow CLI ⇒ leaf IS the task.
- [ ] Every skill has the 6 mandatory sections + the full header.
- [ ] Every skill is DEEP (mental model + 4+ pitfalls + checklist),
      not a flag dump.
- [ ] Recipes verified where the CLI is runnable; un-verifiable ones
      flagged `experimental` and logged.
- [ ] All See-also links resolve.
- [ ] All code blocks balanced; the file parses.
- [ ] Every file < 800 LOC.

## See also

- `../runtime/docs/TOOLKITS-PLAN.md` — format, discovery, distribution.
- `../runtime/docs/TOOLKIT-SKILLS-V2.md` — the depth bar + thick-skill pattern.
- `../runtime/docs/TOOLKIT-DISCOVERY.md` — toolkit node + runtime resolution.
- `ffmpeg/` — the gold-standard exemplar (manifest v0.3.0 + 20 deep skills).
- `toolkit-forge/` — the toolkit that lets a Workbooks agent forge toolkits.
- `../.claude/workflows/forge-toolkit.js` — the workflow that automates this standard.
- `../.claude/skills/forge-toolkit/SKILL.md` — the user-facing `/forge-toolkit` entry.
