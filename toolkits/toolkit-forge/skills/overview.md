# toolkit-forge — overview (the forge loop + the standard)
0.1.0
Use when first reaching for toolkit-forge — the four-phase loop (research → design → author → verify), where the standard lives, and which skill owns each step.

# When to use this
NETWORK: yes
DESTRUCTIVE: no

  First contact with `toolkit-forge`. Read this to orient: what
  "forging a toolkit" means, the four phases, and which skill to `cat`
  next. The job is to turn a TARGET — an npm package name, a GitHub
  URL, or a semantic need ("I need PDF manipulation") — into a complete
  toolkit at `toolkits/<name>/` that an agent can pick up and use
  competently.

  NOT for: a one-off shell command (just run it); editing an existing
  toolkit's prose (edit the `.org` files). For the depth/format rules
  themselves, read [toolkits/AUTHORING.md](../../AUTHORING.md) — this toolkit OPERATES that
  standard, it doesn't restate it.

# The mental model: the substrate is the catalog

  A Workbooks runtime agent has exactly one tool: `bash` (CLAUDE.md
  rule 13). It learns a CLI by reading a toolkit — `manifest.org`
  (the index) + `skills/*.org` (deep recipes read on demand via `cat`).
  Forging a toolkit means producing that directory to the shared
  standard, so the NEXT agent discovers it via the auto-injected
  TOOLKITS index and uses it.

  Two things make a forged toolkit good (both enforced by
  [AUTHORING.md](../../AUTHORING.md)):
  - *Depth* — each skill is recipe + the GOTCHAS + the WHY + a verify
    checklist + see-also, empirically verified. A flag dump is a
    failure.
  - *Progressive disclosure* — the manifest indexes skills by NEED;
    the agent reads ONE skill per task. The skill set must PARTITION
    the surface (every common need owned once).

# The forge loop (four phases, one skill each)

  1. *Research* — resolve the target + fetch its source into a scratch
     dir. [research-target](research-target.md).
  2. *Study* — read the REAL `--help` / README / source to map the
     commands, the gotchas, and the distinct NEEDS (not the flags).
     [study-surface](study-surface.md).
  3. *Design* — pick the toolkit name + CLI_BIN, and the
     need→skill disclosure map (which deep skills exist).
     [design-skills](design-skills.md).
  4. *Author* — write each DEEP skill ([author-deep-skill](author-deep-skill.md)) + the
     [manifest](write-manifest.md) index.
  5. *Verify* — org balance, links resolve, recipes run where
     possible, manifest indexes every skill. [verify-toolkit](verify-toolkit.md).

## confirm the tools the forge needs are present
```bash
  command -v git >/dev/null || { echo "git missing"; exit 1; }
  command -v node >/dev/null || echo "warn: node absent — npm-name targets degrade"
  test -f toolkits/AUTHORING.md || echo "warn: run from the monorepo root (AUTHORING.md not found)"
```

# The automated path vs the by-hand path

  - *Claude Code session*: invoke `/forge-toolkit <target>` — the
    `forge-toolkit` Workflow (`.claude/workflows/forge-toolkit.js`)
    runs all four phases with parallel worktree authors and emits the
    toolkit. You don't need these skills there; they're the manual.
  - *Runtime agent (bash only)*: do it by hand, one skill at a time,
    in the order above. These skills ARE that procedure.

# Common pitfalls

  1. *Authoring from training priors.* The whole point of Research +
     Study is to ground recipes in the tool's ACTUAL surface. A skill
     full of plausible-but-wrong flags is worse than none. Always fetch
     + read the source.
  2. *Shallow skills.* Hitting the section headers but writing
     one-liners reintroduces the exact "skills are thin" bug v2 fixed.
     Depth is the bar — see [author-deep-skill](author-deep-skill.md).
  3. *Skill set that doesn't partition.* Two skills claiming the same
     need, or a common need with no skill, breaks the router. The
     manifest "Use when" column must cover the surface cleanly.
  4. *Skipping verify.* Unbalanced `begin_src`, broken see-also links,
     or a manifest that misses a skill all ship silently without
     [verify-toolkit](verify-toolkit.md).
  5. *Baking in project specifics.* Toolkits are reusable across any
     project. Never hardcode one project's paths into a toolkit skill.

# Verification checklist

  - [ ] You know which of the 3 target kinds you have
  - [ ] You've read [AUTHORING.md](../../AUTHORING.md) before authoring
  - [ ] You'll run the phases in order (research → … → verify)
  - [ ] Output lands at `toolkits/<name>/` with manifest + skills

# See also

  - [toolkits/AUTHORING.md](../../AUTHORING.md) — the depth/breadth standard this operates
  - [research-target](research-target.md) — phase 1, fetch the target
  - [verify-toolkit](verify-toolkit.md) — phase 5, the done-bar
  - `../ffmpeg/` — the gold-standard exemplar toolkit
