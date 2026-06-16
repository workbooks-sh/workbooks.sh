# toolkit-forge — study-surface (map the REAL commands, gotchas, and needs)
0.1.0
Use after fetching a target — read its --help / README / source to map the actual command surface, the non-obvious gotchas, and the distinct agent NEEDS that drive the skill partition.

# When to use this
NETWORK: no
DESTRUCTIVE: no

  Phase 2 of the forge. The source is in `/tmp/forge-<slug>`
  ([research-target](research-target.md)). Now extract the REAL surface so the design +
  authoring are grounded in fact, not training priors. You produce
  three lists: the commands/verbs/flags that exist, the gotchas that
  bite, and the distinct NEEDS an agent will have.

  NOT for: fetching the source ([research-target](research-target.md)); deciding which
  skills exist ([design-skills](design-skills.md) consumes this).

# The mental model: needs ≠ flags

  A man page lists flags. A toolkit indexes NEEDS — the tasks an agent
  reaches for. Your job here is to read the flags but THINK in needs:
  "resize an image", "cap a vision image at 1568px" are needs; =-vf
  scale=…= is the flag that serves them. The needs list is the most
  important output — it becomes the skill partition.

  Sources, in order of trust:
  1. `<bin> --help` + per-subcommand `<bin> <cmd> --help` (if runnable)
  2. the entrypoint source (`bin/`, `src/cli`, the arg parser)
  3. the README + docs/ in the fetched tree
  4. tests (they show real invocations + edge cases)

# Workflow

## Run the help surface if the tool is installable

## confirm the bin is runnable before trusting its --help
```bash
  command -v BIN >/dev/null || { echo "BIN not on PATH — read source/README instead"; exit 1; }
```

## top-level help, then enumerate + dump each subcommand's help
```bash
  BIN --help 2>&1 | tee /tmp/forge-help.txt
  # for tools with subcommands, walk them:
  BIN --help 2>&1 | grep -oE '^\s+[a-z][a-z0-9-]+' | awk '{print $1}' | sort -u \
    | while read -r c; do echo "=== $c ==="; BIN "$c" --help 2>&1 | head -40; done
```

## Read the source entrypoint + README when help is thin (or absent)

## find the CLI entrypoint + the arg parser
```bash
  S=/tmp/forge-SLUG
  # package.json "bin" points at the entry for node CLIs; Cargo.toml [[bin]] for rust
  cat "$S/package.json" 2>/dev/null | grep -A3 '"bin"'
  ls "$S"/{bin,src,cmd,cli} 2>/dev/null
  # the README is the human-facing surface map
  sed -n '1,200p' "$S/README"* 2>/dev/null
```

## tests reveal real invocations + edge cases
```bash
  grep -rEho "BIN [a-z].*" /tmp/forge-SLUG/test* 2>/dev/null | sort -u | head -40
```

## Distill the three lists

  Write them down (these feed [design-skills](design-skills.md)):

  - *commands* — verbs/subcommands/flags that actually exist (quote the
    real syntax; note arg ORDER where it matters).
  - *gotchas* — the traps: arg-order sensitivity, defaults that
    surprise, footguns, "looks right but isn't" (e.g. ffmpeg's
    odd-dimension rejection, `-i` before filters). These become the
    "Common pitfalls" sections.
  - *needs* — the distinct tasks. Each need with its OWN recipe +
    gotchas + verify is a candidate skill.

# Common pitfalls

  1. *Trusting --help over reality.* Some tools' --help omits flags the
     source supports, or vice-versa. Cross-check help against the arg
     parser; when they disagree, the source wins.
  2. *Listing flags instead of needs.* A flag inventory is not a need
     map. Always translate to "what would an agent want to DO".
  3. *Missing the gotchas.* The gotchas are the highest-value content. A
     surface map with no gotchas means you skimmed — re-read the issues,
     the README "caveats", the test edge cases.
  4. *Ignoring arg order.* Many CLIs are position-sensitive (inputs
     before filters, global flags before subcommand). Capture this — it's
     a classic agent failure.
  5. *Over-scoping.* You don't need every flag of a giant tool — capture
     the COMMON surface + gotchas. Exhaustive enumeration belongs in
     `--help` (linked from See-also), not the skills.

# Verification checklist

  - [ ] commands list quotes REAL syntax (verified vs source/help)
  - [ ] gotchas list has the arg-order + surprising-default traps
  - [ ] needs list is in agent-task terms, not flag terms
  - [ ] needs PARTITION the common surface (no big gap, no dupes)
  - [ ] sources cross-checked when help + source disagreed

# See also

  - [research-target](research-target.md) — previous: fetch the source
  - [design-skills](design-skills.md) — next: turn needs into the skill map
  - [author-deep-skill](author-deep-skill.md) — where the gotchas become pitfalls sections
