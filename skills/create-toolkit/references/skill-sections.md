# `skills/<slug>.org` — the six mandatory sections

One file per task/verb. **Depth is the bar** — a skill is the recipe + the
GOTCHAS + the WHY + a verification checklist + see-also, empirically verified
where the tool is runnable. Not a man-page paraphrase, not a flag dump. Target
150–300 body lines; below ~120, ask whether you went deep. Source:
`toolkits/AUTHORING.md §"=skills/<slug>.org="`. Exemplars:
`toolkits/ffmpeg/skills/image-resize.org`, `.../lossy-tradeoffs.org`.

## Header (every key load-bearing)

```org
#+TITLE: <toolkit> — <task, with the key gotcha hinted>
#+TOOLKIT: <toolkit>          # == manifest #+TOOLKIT
#+SKILL: <slug>               # == filename without .org
#+VERSION: <skill semver, independent of toolkit version>
#+DESCRIPTION: Use when <trigger>. <one-line behavior + the knobs covered>.
#+TAGS: <space-separated lookup tags — verbs + nouns the agent searches>
#+STATUS: stable | experimental | deprecated
```

## The six sections, in this order

1. **`* When to use this`** — a `:PROPERTIES:` drawer carrying runtime-honored
   flags, then a trigger paragraph AND an explicit `NOT for: <x>
   ([[file:other.org][other]])` line.

   ```org
   * When to use this
     :PROPERTIES:
     :NETWORK:     no            # yes ⇒ skipped offline, declares cost
     :DESTRUCTIVE: no            # yes ⇒ agent confirms before running
     :REQUIRES:    <extra CLIs>  # optional; pre-flight at load
     :OS:          macos linux   # optional; skipped on mismatch
     :COST:        free          # free | paid; gates live-API skills
     :END:

     <1 paragraph: the exact situation that routes here.>
     NOT for: <adjacent need> ([[file:adjacent.org][adjacent]]).
   ```

2. **`* The mental model`** (or a named concept section) — the WHY before the HOW.
   The table/paragraph that makes the recipes make sense (ffmpeg: the
   `scale=W:H` with `-1/-2` table). Skip only for genuinely single-step skills.

3. **`* Workflow`** — numbered/sub-headed steps, each a `#+CAPTION`'d src block.
   Wrap the recipe in verification blocks:

   ```org
   #+CAPTION: <precondition — the TOC entry>
   #+begin_src bash :role pre
   <input exists? tool the right version?>
   #+end_src

   #+CAPTION: <the actual recipe>
   #+begin_src bash
   <the command(s)>
   #+end_src

   #+CAPTION: <confirm it worked>
   #+begin_src bash :role post :path <output>
   <output exists / is valid>
   #+end_src
   ```

   Every code block gets a `#+CAPTION:` (it is the surfaced TOC). `:role pre` runs
   before the agent suggests the recipe; `:role post` validates after; `:role
   task` is a runnable multi-verb recipe invoked by `work toolkit run`. `$1` in a
   role block is the path the runtime passes. **Security:** `:role` blocks are
   arbitrary host bash — they run ONLY when `WB_TOOLKIT_EXEC=1`, under the sandbox
   (network-denied, fs-confined, ulimit-capped); unset ⇒ reported SKIPPED.

4. **`* Common pitfalls`** — numbered, each *mistake → why → fix*. The
   highest-value section: things that look right after a `--help` skim but bite.
   Aim for 4–6 real ones, empirically found.

5. **`* Verification checklist`** — `- [ ]` boxes the agent ticks after running.
   Concrete, checkable (run `ffprobe`, `grep`, `file`), not vibes.

6. **`* See also`** — `[[file:other.org][label]]` links to sibling skills by
   INTENT ("when you start from someone else's file"), plus the authoritative
   man-page escape hatch (`ffmpeg -h filter=scale`). **Every link target must
   exist** (verify checks this).

## Thick skills

For a large sub-surface use `skills/<slug>/SKILL.org` +
`skills/<slug>/references/<topic>.org` — the SKILL.org is the front door and
points at references by file path. Default to a flat single file; reach for the
dir only when one skill genuinely needs deep-dives (signal: >~400 lines).

## The depth/breadth bar (the consistency contract)

- Deep, not shallow — recipe + gotchas + WHY + checklist + see-also.
- Empirically verified where runnable; un-verifiable ⇒ `#+STATUS: experimental`
  and logged.
- Consistent, NOT deterministic — same SHAPE/DEPTH/section-set across authors,
  not byte-identical prose. Don't template-fill; write real recipes for real needs.
- Breadth = the common surface + the gotchas that bite + `overview.org`; leave
  exhaustive flag enumeration to `--help` (linked from See also).
- General + reusable — never bake one project's paths/assumptions into a skill.
- Under budget — each file < 800 LOC.
