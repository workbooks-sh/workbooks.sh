# toolkit-forge — design-skills (the need→skill progressive-disclosure map)
0.1.0
Use after studying the surface — decide the toolkit name + CLI_BIN and partition the needs into the deep-skill set that the manifest will index by need.

# When to use this
NETWORK: no
DESTRUCTIVE: no

  Phase 3 of the forge. You have the surface map ([study-surface](study-surface.md)).
  Now decide the toolkit's identity (name, CLI_BIN, version range,
  status, tagline) and — the heart of the job — the PROGRESSIVE-
  DISCLOSURE MAP: which deep skills exist, each keyed by the need that
  routes to it.

  NOT for: writing the skills ([author-deep-skill](author-deep-skill.md)) or the manifest
  ([write-manifest](write-manifest.md)); those realize this design.

# The mental model: one need with its own gotchas = one skill

  From [AUTHORING.md §"Progressive disclosure"](../../AUTHORING.md): the manifest is the
  INDEX, skills are read on demand. The skill set must PARTITION the
  surface — every common need owned by exactly one skill, no two skills
  claiming the same need.

  The partition rule:
  - One need that has its OWN recipe + gotchas + verify ⇒ its own skill.
  - Needs that share a recipe ⇒ merge into one skill.
  - A need that branches into materially different recipes ⇒ split
    (ffmpeg split "scale image" vs "scale video": the even-dim/SAR
    gotchas differ enough to warrant two).

  Match the surface, NOT a quota. A focused CLI may warrant 5 skills; a
  huge one 15-20. Always include `overview`.

# Workflow

## Decide identity

  - *name* (slug): clean, whitespace-free, == dir name. Default to the
    bin name (`ffmpeg`, `git`); for a semantic need, name it after the
    chosen tool. The user may force a name.
  - *CLI_BIN*: the executable on PATH. ("" only if it's a library, not
    a CLI — rare for a toolkit.)
  - *CLI_VERSION_RANGE*: the range your recipes are written against
    (=>`6.0`).
  - *STATUS*: `stable` only if you verified recipes; else `experimental`.
  - *TAGLINE*: one sentence — when to reach for this toolkit.
  - *REQUIRES*: extra CLIs the skills assume (=node>`20 npm`), or omit.

## Deep CLI? Partition the TASKS first (the task tier)

  Before the leaf skills, decide if the CLI is DEEP (see the depth
  heuristic in `toolkits/AUTHORING.md`: `#+FLOW` chains >=3 verbs, OR
  >=6 verb groups, OR a verb nests >=2 levels like =social <platform>
  <kind>=). If so, the toolkit MUST ship a TASK tier ABOVE the leaves —
  "wrap the SEQUENCE, not the verb". From the surface's
  `multi_verb_tasks`, for each common cross-verb NEED ("harvest a
  brand's social presence", "publish + verify a deck") author ONE
  runnable recipe whose input is the user's NOUN (`<domain>`), not a
  verb chain — it OWNS the dirty work (discovery, fan-out, lane writes).
  Make it runnable by OWNERSHIP (AUTHORING.md §How a task is made
  runnable): a CLI we own → an UPSTREAM task-verb; a CLI we don't own →
  a `:role task`-tagged bash source block run via
  `wb toolkit run <toolkit> <task> -- <args>`. The manifest indexes
  TASKS above leaves; the agent reaches for the task by default. A
  SHALLOW CLI skips this — there the leaf IS the task.

## Partition the needs into skills

  For each skill record: `slug`, the `use_when` NEED (the manifest
  router cell, in the agent's words), the optional `group`, `thick?`
  (only if it needs deep-dives → `SKILL.org + references/`), and
  `covers` (the real commands/gotchas it must teach, from the surface).

## sanity — the needs you mapped should each land in exactly one skill
```bash
  # study-surface produced a needs list; check your skill set covers each once.
  # (do this as a written cross-check; example shape:)
  echo "need: resize image      -> skill: image-resize"
  echo "need: crop/pad image    -> skill: image-crop-pad"
  echo "need: convert format    -> skill: image-convert"
  # ...every need maps to exactly one slug; no slug owns two unrelated needs.
```

## Group + bundle

  - *Group* manifest rows with `*— GROUP —*` only when the surface
    splits cleanly AND there are ≥6 skills (ffmpeg: IMAGE/VIDEO).
    Otherwise no groups.
  - *Bundle* for parallel authoring (if using the Workflow): split
    skills into non-overlapping, balanced bundles (~3-6 each), keeping
    related skills together so one author owns a coherent slice.

## the design is sound when the map round-trips
```bash
  # every studied need appears as a use_when; overview present; no dup slugs.
  echo "design checklist: needs-covered ✓  overview ✓  unique-slugs ✓"
```

# Common pitfalls

  1. *Padding to a quota.* Inventing skills to "look thorough" creates
     thin, overlapping files. Map the real surface; stop there.
  2. *Starving a big surface.* The opposite: cramming many needs into
     one mega-skill. If a skill would exceed ~400 lines, it's two
     skills (or a thick `SKILL.org + references/`).
  3. *use_when restates the slug.* "trim a video" for a skill named
     `trim` teaches nothing. Phrase the need as the AGENT'S trigger:
     "cut a slice — first N sec / between two times".
  4. *Forgetting overview.* Every toolkit ships `overview.org` as the
     "is this the right toolkit?" stop.
  5. *Non-partitioning set.* Two skills both claiming "resize", or no
     skill owning a common need — the router breaks. Cross-check the
     needs list against the slug list.
  6. *Inventing groups for a tiny toolkit.* <6 skills needs no group
     rows; it adds noise.

# Verification checklist

  - [ ] name / CLI_BIN / version range / status / tagline decided
  - [ ] every studied NEED maps to exactly one skill
  - [ ] `overview` in the set
  - [ ] use_when cells are needs-in-agent-words, not slug restatements
  - [ ] groups only if ≥6 skills + clean split
  - [ ] bundles non-overlapping + balanced (if parallel-authoring)

# See also

  - [study-surface](study-surface.md) — previous: the needs list this consumes
  - [author-deep-skill](author-deep-skill.md) — next: realize each skill in the map
  - [write-manifest](write-manifest.md) — build the index from this map
  - [toolkits/AUTHORING.md](../../AUTHORING.md) — the partition + disclosure rules
