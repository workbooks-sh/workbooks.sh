# git

A skill-driven wrapper around the standard `git` binary. The skills cover the workflows agents commonly need but tend to get wrong from training-data priors alone: rebasing without losing work, recovering a detached HEAD, undoing a commit (pushed vs. not), and inspecting/resolving merge conflicts — recipes the agent can lift verbatim.

## When to reach for it

Reach for `git` whenever version-control work goes beyond `add`/`commit`/`push` and into territory where a wrong incantation loses work — recovery, rebase, bisect, cherry-pick, partial staging, worktrees, submodules.

## Example

```
# git says "HEAD detached at <sha>" — recover without losing the work:
git switch -c rescue            # name the detached state as a branch
# or move a branch onto updated main safely:
git rebase --onto main old-base feature
```

## What it grants

- Recipes for: detached-HEAD recovery, rebase without losing work, safe commit undo, bisect, cherry-pick, partial staging (`git add -p`), worktree management, submodule flows.
- Each is an end-to-end task recipe, not a man-page substitute — `git --help` and `git <verb> --help` stay authoritative for flags.

## Maturity

Stable. Requires git 2.30+.
