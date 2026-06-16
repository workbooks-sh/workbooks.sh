# git — cherry-pick commits across branches
0.1.0
Use when you need to apply a specific commit (or range) from one branch onto another, without merging the whole branch. Handles conflicts + range syntax + the --no-commit pattern.

# When to use this
NETWORK: no
DESTRUCTIVE: no

  - Backport a fix from main to a release branch
  - Lift one commit from a long-lived branch without merging
    the rest
  - Re-apply a commit you reverted earlier
  - Reconstruct a subset of an abandoned branch's work

  NOT for: applying whole branches (use merge or rebase);
  rewriting history in-place (use rebase -i).

# Workflow

## Single-commit cherry-pick

## confirm clean tree + we're on the target branch
```bash
   git status --porcelain | grep -q . \
     && { echo "uncommitted changes — stash first"; exit 1; }
   git branch --show-current
```

## apply one commit by SHA
```bash
   git cherry-pick <SHA>
   # creates a NEW commit on the current branch with the same diff
   # the new SHA differs; original commit unchanged
```

## Range cherry-pick

## apply a range — A^..B is "after A, up to B inclusive"
```bash
   git cherry-pick A^..B
   # excludes A itself; use A..B to also exclude A (rare)
```

## Edit before commit (review + amend before recording)

## stage the changes without auto-committing
```bash
   git cherry-pick --no-commit <SHA>
   # now edit files, change message, etc.
   git commit -m "backport: <SHA> + adapted for legacy schema"
```

## Skip-on-empty (commit already applied)

## tolerate "nothing to commit" outcomes
```bash
   git cherry-pick --keep-redundant-commits  <SHA>
   # alternative: --allow-empty to keep empty commits in the history
```

# Conflict resolution mid-cherry-pick

  If a cherry-pick hits a conflict, git stops with the
  conflict markers in the working tree:

## see what's conflicted
```bash
  git status
  # "Unmerged paths" section lists the conflicted files
```

## resolve + continue
```bash
  # edit each file, remove <<<<<<< / ======= / >>>>>>> markers
  git add <resolved-files>
  git cherry-pick --continue
```

## bail out, return to pre-cherry-pick state
```bash
  git cherry-pick --abort
```

# Common pitfalls

  1. *Cherry-picked commit has a different SHA.* Even if the diff
     is byte-identical, the commit metadata (parent, timestamp)
     differs. Don't refer to the old SHA after cherry-pick; use
     the new one.

  2. *Lost authorship on cherry-pick across maintainers.* Default
     keeps the original author + sets committer to you. Pass
     `-x` to add a "(cherry picked from commit <SHA>)" trailer
     so the audit trail survives.

  3. *Empty cherry-pick when commit is already applied.* git stops
     and asks; pass `--allow-empty` or `--skip` depending on whether
     you want to keep the empty commit or drop it.

  4. *Cherry-picking a merge commit.* Requires `-m N` to pick a
     parent side. Usually you want `-m 1` (mainline parent), but
     verify by inspecting the merge's parents first.

  5. *Cherry-picking past a refactor that renamed files.* git's
     rename detection sometimes fails; the cherry-pick conflicts
     on a "deleted" file in the target branch. Resolve by manually
     mapping the new path.

# Verification checklist

  - [ ] New commit appears on current branch (`git log --oneline -3`)
  - [ ] Diff matches expectations (`git show HEAD`)
  - [ ] Tests pass at the new commit (if applicable)
  - [ ] If conflict was hit: `git cherry-pick --continue` or `--abort` cleared the state

# See also

  - [rebase-without-losing-work](rebase-without-losing-work.md) — when you want a whole branch, not one commit
  - [undo-a-commit-safely](undo-a-commit-safely.md) — to revert a cherry-pick that broke something
