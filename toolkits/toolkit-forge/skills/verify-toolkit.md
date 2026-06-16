# toolkit-forge — verify-toolkit (org balance, links resolve, recipes run, index whole)
0.1.0
Use as the final forge phase — run the checks that prove a forged toolkit is done: org src blocks balanced, every see-also link resolves, the manifest indexes every skill, drawer matches keywords, recipes run where possible, files under budget.

# When to use this
NETWORK: no
DESTRUCTIVE: no

  Phase 5 of the forge — the done-bar. The manifest + skills exist;
  before declaring the toolkit live, run these checks. Fix anything
  cheap in-place; report what you couldn't (e.g. a tool you couldn't
  install to run recipes).

  NOT for: writing content ([author-deep-skill](author-deep-skill.md) / [write-manifest](write-manifest.md)). This
  is the gate, mirroring [AUTHORING.md §"Authoring checklist"](../../AUTHORING.md).

# The mental model: cheap structural checks catch silent failures

  Most forge failures are silent: an unbalanced `begin_src`, a
  see-also link to a skill that doesn't exist, a skill missing from the
  manifest. Each is a one-line grep to catch. Run them all; a green
  board is the done-bar.

# Workflow

## Org src-block balance

## pre — there is a toolkit to check
```bash
  test -d "toolkits/$1" || { echo "toolkit toolkits/$1 not found"; exit 1; }
```

## every #+begin_src has a matching #+end_src (note: comma-escaped lines in org examples don't count — count real directives)
```bash
  TK="toolkits/NAME"
  for f in "$TK"/manifest.org "$TK"/skills/*.org; do
    b=$(grep -c '^#+begin_src' "$f"); e=$(grep -c '^#+end_src' "$f")
    [ "$b" = "$e" ] || echo "UNBALANCED $f: begin=$b end=$e"
  done
  echo "balance check done"
```

  Note: inside an org skill that DOCUMENTS org (like this toolkit), the
  example blocks are comma-escaped (`,#+begin_src`) so they don't count
  as real directives — only un-escaped `^#+begin_src` do.

## See-also links resolve

## every [file:NAME.org](file:NAME.org) target exists in the toolkit
```bash
  TK="toolkits/NAME"
  grep -rhoE '\[\[file:[^]]+\.org' "$TK"/skills | sed -E 's#\[\[file:##' | sort -u \
  | while read -r rel; do
      # resolve relative to skills/ (handles ../ to AUTHORING.md etc.)
      ( cd "$TK/skills" && test -e "$rel" ) || echo "DANGLING LINK: $rel"
    done
  echo "link check done"
```

## Manifest indexes every skill exactly once

## diff the table's skill rows against the skills dir
```bash
  TK="toolkits/NAME"
  for f in "$TK"/skills/*.org; do
    s=$(basename "$f" .org)
    grep -q "=$s=" "$TK/manifest.org" || echo "NOT INDEXED: $s"
  done
  test -f "$TK/skills/overview.org" || echo "MISSING overview.org"
  echo "index check done"
```

## Drawer matches keywords + files under budget

## :ID:/:CLI_BIN:/:STATUS: equal the #+ keywords; no file > 800 LOC
```bash
  TK="toolkits/NAME"; M="$TK/manifest.org"
  kw(){ grep -m1 "^#+$1:" "$M" | sed -E "s/^#\+$1:[[:space:]]*//"; }
  dr(){ grep -m1 ":$1:" "$M" | sed -E "s/.*:$1:[[:space:]]*//"; }
  [ "$(kw TOOLKIT)" = "$(dr ID)" ]      || echo "ID != #+TOOLKIT"
  [ "$(kw CLI_BIN)" = "$(dr CLI_BIN)" ] || echo "CLI_BIN drawer != keyword"
  [ "$(kw STATUS)"  = "$(dr STATUS)" ]  || echo "STATUS drawer != keyword"
  awk 'END{if(NR>800)print FILENAME" OVER 800 LOC: "NR}' "$M" "$TK"/skills/*.org
  echo "drawer + budget check done"
```

## Recipes run where the tool is installable

## if the bin installs, run each skill's headline recipe + role-post on a fixture
```bash
  command -v BIN >/dev/null || { echo "BIN absent — recipes unverified; skills should be #+STATUS: experimental"; exit 0; }
  # for each skill: create a tiny fixture, run its main recipe, assert the post check.
  echo "ran recipes against BIN where possible; record results"
```

# Common pitfalls

  1. *Counting comma-escaped org examples.* In skills that document org,
     `,#+begin_src` is an ESCAPED example, not a real directive. Count
     only `^#+begin_src` / `^#+end_src` so the balance check isn't false.
  2. *Resolving links from the wrong dir.* `[file:...](file:...)` is relative to
     the skill file (`skills/`). `../AUTHORING.md` resolves to the
     toolkit root; `../../` to `toolkits/`. Resolve from `skills/`.
  3. *Declaring stable without running recipes.* If `BIN` wasn't
     installable, the toolkit is `experimental` and you say so — don't
     claim verification you didn't do.
  4. *Fixing nothing, reporting everything.* Cheap fixes (a missing
     index row, a typo'd link) — just fix them. Only escalate the real
     blockers (a recipe you genuinely can't validate).
  5. *Ignoring the 800-LOC cap.* A skill over budget must split into a
     thick `SKILL.org + references/` (see [author-deep-skill](author-deep-skill.md)).

# Verification checklist

  - [ ] All src blocks balanced (real directives only)
  - [ ] No dangling see-also links
  - [ ] Manifest indexes every skill exactly once; `overview` present
  - [ ] Drawer `:ID:/:CLI_BIN:/:STATUS:` =` the `#+= keywords
  - [ ] Every file < 800 LOC
  - [ ] Recipes run where the bin installs; unverifiable ones flagged
        `experimental` + logged
  - [ ] The toolkit is live for Claude Code; note the engine deploy
        needed to bake it for runtime agents

# See also

  - [write-manifest](write-manifest.md) — previous: the index this checks
  - [author-deep-skill](author-deep-skill.md) — fix depth/format issues this surfaces
  - [overview](overview.md) — the full forge loop
  - [toolkits/AUTHORING.md](../../AUTHORING.md) — the authoring checklist this mirrors
