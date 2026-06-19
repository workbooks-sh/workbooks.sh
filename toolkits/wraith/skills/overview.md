# wraith — overview

# When to use this
NETWORK: no
DESTRUCTIVE: no

  About to push a branch or open a PR and want a quick sweep
  for dead code, over-complex functions, and unused deps.
  Wraith catches the slow-creep cruft before reviewers do.

  Also useful mid-refactor: "this function feels gnarly" → run
  `wraith health --fn <path>` for a structured branch tree +
  extraction suggestions.

# What wraith won't do

  - Behavior testing — wraith is static analysis only.
  - Type checking — that's rustc / tsc.
  - Formatting — that's rustfmt / prettier.

# Verify

## confirm wraith is installed
```bash
  command -v wraith >/dev/null || { echo "wraith missing — cargo install --path projects/wraith"; exit 1; }
  wraith --help 2>&1 | head -1
```

# See also

  - [clean-up-a-rust-package](clean-up-a-rust-package.md) — full sweep on a single package
  - [reduce-complexity](reduce-complexity.md) — refactor a flagged function
  - [boundary-enforcement](boundary-enforcement.md) — codify import-layering rules
  - [fix-write-workflow](fix-write-workflow.md) — apply automated removals safely
  - [refactor-extract-fn](refactor-extract-fn.md) — extract a sub-tree from a complex fn
  - [slop-suppression-policy](slop-suppression-policy.md) — triage `wraith slop` findings
