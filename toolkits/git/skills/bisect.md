# git — bisect to find the breaking commit
0.1.0
Use when something works on an old commit and broke at some recent commit, and you need to find which commit introduced the break. Binary search via `git bisect`.

# When to use this
NETWORK: no
DESTRUCTIVE: no

  A test / behavior / feature works at one commit (the "good"
  one) and fails at HEAD. You want to find the single commit
  that introduced the break. Bisect halves the search space
  per step — log₂(N) commits to identify.

  Not for: finding WHERE in the diff the bug lives (use blame
  / interactive review); rewriting history (use rebase); or
  finding multiple unrelated breakages (bisect finds ONE).

# Workflow

## 1. confirm working tree is clean (bisect needs to checkout commits)
```bash
  git status --porcelain | grep -q . \
    && { echo "uncommitted changes — stash or commit first"; exit 1; }
  echo "clean ✓"
```

## 2. start bisect — provide a known-bad + known-good commit
```bash
  git bisect start
  git bisect bad HEAD                    # current commit is broken
  git bisect good v1.2.0                 # last known-good tag (or sha)
  # git checks out the midpoint; you test it
```

## 3. test the checked-out commit; mark good or bad
```bash
  # run your test command; based on outcome:
  git bisect good     # → still works at this commit; break is later
  # OR
  git bisect bad      # → broken at this commit; break is earlier
  # git checks out the next midpoint automatically
```

  Repeat until git prints `<sha> is the first bad commit`.

## 4. always reset bisect state when done
```bash
  git bisect reset
  # returns HEAD to its pre-bisect position
```

# Automated bisect

  Pass a test script and let git iterate without prompting:

## bisect with an automated pass/fail check
```bash
  git bisect start HEAD v1.2.0     # bad then good as positional args
  git bisect run npm test          # exit 0 = good, non-zero = bad
  # git iterates until it isolates the breaking commit
  git bisect reset
```

  Test script exit-code rules:
  - exit 0 = commit is good
  - exit 125 = commit can't be tested (skip — common for build errors
    that aren't the regression you're hunting)
  - any other non-zero = bad

## verify the result is reproducible
```bash
  # at the identified commit, re-run your test
  npm test
  # exit code should match what bisect concluded
```

# Common pitfalls

  1. *Forgetting `git bisect reset`.* You'll stay in detached-HEAD
     state on a midpoint commit. Always reset when done.

  2. *Dirty working tree.* Bisect checks out commits; uncommitted
     changes get clobbered or fail the checkout. Stash first
     (`git stash`) and pop after reset.

  3. *Build/setup errors mid-bisect.* If the checked-out commit
     fails to BUILD (not the regression you're hunting), don't
     mark it bad — use `git bisect skip`. With auto-bisect, return
     exit 125.

  4. *Merge commits + first-parent.* If your repo uses merge
     commits, `git bisect` walks all parents by default. Pass
     `--first-parent` to bisect to walk only the trunk if the
     break is on the trunk's merges.

# Verification checklist

  - [ ] `git bisect reset` ran (HEAD is back on a branch)
  - [ ] Stash popped if you stashed pre-bisect
  - [ ] Identified commit reproducibly fails the test
  - [ ] Parent of identified commit reproducibly passes the test

# See also

  - [undo-a-commit-safely](undo-a-commit-safely.md) — once you've found the bad commit
  - [overview](overview.md) — when to reach for the git toolkit
