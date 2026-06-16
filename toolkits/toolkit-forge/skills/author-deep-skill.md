# toolkit-forge — author-deep-skill (write ONE deep, verified skill to the spec)
0.1.0
Use when writing a single skill file — the mandatory header + 6 sections, the role pre/post verify blocks, and how to make it DEEP (mental model + gotchas + why) and empirically verified, not a flag dump.

# When to use this
NETWORK: no
DESTRUCTIVE: no

  Phase 4 of the forge, per skill. The design ([design-skills](design-skills.md)) gave
  you a slug + a need + what it must cover. Now write
  `toolkits/<name>/skills/<slug>.org` to the standard — DEEP, verified
  where the tool runs.

  NOT for: the manifest index ([write-manifest](write-manifest.md)); deciding the skill
  set ([design-skills](design-skills.md)). For the full format spec read
  [AUTHORING.org §"skills/<slug>.org"](../../AUTHORING.md); this is the operational how-to.

# The mental model: depth is the bar

  Depth = recipe + the GOTCHAS + the WHY + a verify checklist +
  see-also. The fastest way to fail is to hit the section headers with
  one-liners — that reintroduces the "skills are thin" bug. Target
  150-300 body lines. Always study the exemplar before writing:
  `cat ../ffmpeg/skills/image-resize.org`.

# Workflow

## Header — every key load-bearing

## the mandatory frontmatter (match ffmpeg exactly)
```org
  ,#+TITLE: <toolkit> — <task, with the key gotcha hinted>
  ,#+TOOLKIT: <toolkit>
  ,#+SKILL: <slug>            # == filename without .org
  ,#+VERSION: 0.1.0           # skill semver, independent of toolkit
  ,#+DESCRIPTION: Use when <trigger>. <one-line behavior + knobs covered>.
  ,#+TAGS: <verbs + nouns the agent searches>
  ,#+STATUS: stable | experimental   # experimental until recipes verified
```

## The 6 mandatory sections, in order

  1. `* When to use this` — a `:PROPERTIES:` drawer (`:NETWORK:`,
     `:DESTRUCTIVE:`, optional `:REQUIRES:/:OS:/:COST:`), a trigger
     paragraph, AND an explicit "NOT for: <x> ([other](other.md))" line.
  2. `* The mental model` — the WHY before the HOW. The table/paragraph
     that makes the recipes make sense. (Skip only for truly one-step
     skills.)
  3. `* Workflow` — sub-headed steps, each a `#+CAPTION:`'d src block,
     wrapped in verify blocks (below).
  4. `* Common pitfalls` — numbered, each *mistake → why → fix*. 4-6
     real ones from [the gotchas you studied](study-surface.md). Highest-value section.
  5. `* Verification checklist` — `- [ ]` boxes the agent ticks, each
     concretely checkable (run `ffprobe`/`grep`/`file`).
  6. `* See also` — `[label](other.md)` links to siblings by
     INTENT + the man-page escape hatch (`<bin> --help`). Links MUST
     resolve.

## Wrap recipes in role pre/post blocks

## the verify-wrapped recipe pattern
```org
  ,#+CAPTION: <precondition — input exists? right version?>
  ,#+begin_src bash :role pre
  test -f "$1" || { echo "input $1 missing"; exit 1; }
  ,#+end_src

  ,#+CAPTION: <the actual recipe>
  ,#+begin_src bash
  BIN do-the-thing in.x out.y
  ,#+end_src

  ,#+CAPTION: <postcondition — output valid?>
  ,#+begin_src bash :role post :path out.y
  test -f "$1" || { echo "output missing"; exit 1; }
  ,#+end_src
```

  `:role pre` runs before the agent suggests the recipe; `:role post`
  after, to validate. `$1` is the path the runtime passes. Every code
  block gets a `#+CAPTION:` (it's the surfaced TOC).

## Verify empirically where the tool runs

## if the bin is installable, RUN the headline recipe on a fixture
```bash
  command -v BIN >/dev/null || { echo "BIN absent — mark skill experimental, sanity-check vs source only"; exit 0; }
```

## e.g. make a tiny fixture, run the recipe, confirm the post check
```bash
  # create a minimal input, run the skill's own recipe, assert the output
  BIN do-the-thing fixture.in /tmp/out.x && test -s /tmp/out.x && echo "verified"
```

  If you cannot install the tool, mark the skill =#+STATUS:
  experimental=, sanity-check the recipe against `/tmp/forge-<slug>`
  source/README, and record it as unverifiable.

# Common pitfalls

  1. *Headers without depth.* Filling the 6 sections with one-liners
     passes a structure check but fails the bar. Each section earns its
     place — pitfalls are real, the mental model actually explains.
  2. *Recipes from memory.* Use the commands you studied, with REAL
     syntax + arg order. A plausible-but-wrong flag is the worst output.
  3. *Unbalanced src blocks.* Every `#+begin_src` needs an `#+end_src`.
     [verify-toolkit](verify-toolkit.md) greps for this — but balance as you write.
  4. *Dangling see-also links.* `[file:foo.org](file:foo.org)` must point at a real
     sibling. Link only skills that exist in this toolkit.
  5. *No CAPTION on a block.* Captions are the agent's TOC; an
     un-captioned block is invisible to block-picking.
  6. *Project-specific paths.* Write general, reusable usage — never
     bake in one project's directories.
  7. *Claiming `stable` without running it.* If you didn't run it, it's
     `experimental`. Don't overstate verification.

# Verification checklist

  - [ ] Full header present (TITLE/TOOLKIT/SKILL/VERSION/DESCRIPTION/TAGS/STATUS)
  - [ ] All 6 sections present, in order
  - [ ] Mental model + 4-6 real pitfalls + checkable checklist
  - [ ] Every src block has a CAPTION; recipes wrapped in role pre/post
  - [ ] All see-also links resolve
  - [ ] Recipe RUN where the bin is installable; else marked experimental
  - [ ] File < 800 LOC (>~400 ⇒ split to thick SKILL.org+references/)

# See also

  - [design-skills](design-skills.md) — where this skill's slug + need came from
  - [write-manifest](write-manifest.md) — index this skill after writing
  - [verify-toolkit](verify-toolkit.md) — the final balance/link/recipe checks
  - [toolkits/AUTHORING.org](../../AUTHORING.md) — the full format spec
  - `../ffmpeg/skills/image-resize.org` — the exemplar to match
