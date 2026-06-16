# git — overview

# When to use this
NETWORK: no
DESTRUCTIVE: no

  Reach for these skills when the agent encounters a git task
  beyond `git add` / `git commit` / `git push` — the common-but-
  dangerous workflows where model priors often suggest the wrong
  recipe (force-push, `git reset --hard`, `git checkout .`).

  For simple stage-commit-push, plain bash + `git --help` is
  fine. These skills cover the recovery + rewrite operations
  where getting it wrong loses work.

# What this toolkit deliberately doesn't cover

  - git internals (plumbing commands, refs, object model)
  - GitHub-specific verbs — use the `gh` toolkit
  - Workbooks federation via Radicle — see `wb`

# Verify

## confirm git is installed at a workable version
```bash
  command -v git >/dev/null || { echo "git missing"; exit 1; }
  git --version
```

## confirm we're in a git repo (most skills assume this)
```bash
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "not inside a git work tree"; exit 1; }
```

# See also

  - [recover-from-detached-head](recover-from-detached-head.md) — get back to a branch safely
  - [rebase-without-losing-work](rebase-without-losing-work.md) — move a branch onto updated main
  - [undo-a-commit-safely](undo-a-commit-safely.md) — revert vs reset vs amend
  - [bisect](bisect.md) — binary-search the commit that introduced a regression
  - [cherry-pick](cherry-pick.md) — apply one commit (or range) from another branch
  - [partial-staging](partial-staging.md) — split a dirty file into multiple commits
  - [worktree-management](worktree-management.md) — have two branches checked out simultaneously
  - [submodule-flows](submodule-flows.md) — init / bump / remove submodules

  When uncertain about a verb: `git <verb> --help`.
