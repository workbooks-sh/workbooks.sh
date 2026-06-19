# wraith — apply automated removals safely (`wraith fix --apply`)
0.1.0
Use when `wraith dead-code` + `wraith unused-deps` have surfaced findings and you want wraith to remove them. Always dry-run first, then `--apply`. Etiquette: small batches, atomic commits, tests after.

# When to use this
NETWORK: no
DESTRUCTIVE: yes
REQUIRES: wraith>=0.0.0 cargo

  `wraith dead-code` and `wraith unused-deps` have produced a
  finding list; you trust enough of the findings that running
  the automated removal beats hand-editing. `wraith fix`
  performs the removals.

  Not for: removing complex multi-file refactors (use =wraith
  refactor= subcommands); pruning non-Rust dependencies (wraith
  fix is Cargo + Rust-source aware); or removing items wraith
  hasn't flagged (it won't).

# The flag surface (ground truth)

  `wraith fix` takes exactly one flag:

## verify the surface
```bash
  command -v wraith >/dev/null || { echo "wraith missing"; exit 1; }
  wraith fix --help
  # → "Auto-remove dead pub items + unused deps (dry-run by default)"
  # → Options: --apply
```

  Behavior summary (verified from `wraith fix --help`):

  | Invocation             | What happens                                                              |
  |------------------------|---------------------------------------------------------------------------|
  | `wraith fix`           | DRY RUN. Prints what WOULD be removed. Writes nothing.                    |
  | `wraith fix --apply`   | Applies removals to source files + `Cargo.toml`. Edits in place.          |

  There is no `--write` flag (that name appears in some older
  notes — the actual flag is `--apply`). There is no
  `--no-confirm` or per-file filter today; treat the whole
  workspace as the unit.

# Workflow

## Step 1 — see what dead-code thinks

## full dead-code report (human-readable)
```bash
   wraith dead-code
```

## same in JSON so you can grep / count
```bash
   wraith --format json dead-code | jq 'length'
   wraith --format json dead-code | jq -r '.[] | "\(.file):\(.line) \(.symbol)"' | head -20
```

## Step 2 — see what unused-deps thinks

## deps that no module actually imports
```bash
   wraith unused-deps
```

## Step 3 — dry-run the fix

## what would change, exactly
```bash
   wraith fix
   # Reports each pub item to be deleted + each Cargo.toml line to be dropped.
   # Does NOT modify the working tree.
```

   Read this output carefully. Spot-check 3-5 of the proposed
   removals by hand:

## confirm a "dead" item really has zero callers
```bash
   git grep -nF 'function_name_wraith_flagged' || echo "no references — safe"
```

   If the dead-code list contains items you want to KEEP (e.g.
   public-API surface kept for downstream users), add them to
   `allow_dead` in `.wraithrc.json` BEFORE applying:

## keep a flagged symbol — won't be deleted
```json
   {
     "allow_dead":        ["my_crate::keep_this_pub_fn"],
     "allow_unused_deps": ["serde_with"]
   }
```

   Re-run `wraith fix` (still dry-run) and confirm the allowlisted
   items are no longer listed.

## Step 4 — commit the working tree first

   `--apply` edits in place. A clean baseline makes review
   trivial.

## snapshot the current tree
```bash
   git status --porcelain | grep -q . \
     && { echo "uncommitted changes — commit or stash before --apply"; exit 1; }
   echo "clean ✓"
```

## Step 5 — apply

## actually do the removals
```bash
   wraith fix --apply
```

## see what wraith touched
```bash
   git status --short
   git diff --stat
```

## Step 6 — verify the workspace still builds + tests pass

## compile every target
```bash
   cargo check --workspace --all-targets
```

## run tests
```bash
   cargo test --workspace
```

## lint sweep (catches secondary issues post-removal)
```bash
   cargo clippy --workspace --all-targets -- -D warnings
```

## Step 7 — commit in small reviewable batches

   If the diff is large, split into logical commits:

## split unused-deps and dead-code into separate commits
```bash
   git add '**/Cargo.toml'
   git commit -m "deps: drop unused deps surfaced by wraith"

   git add -u
   git commit -m "cleanup: remove dead pub items surfaced by wraith"
```

# Common pitfalls

  1. *Used `--write` and got "unrecognized flag".* The flag is
     `--apply`. `--write` is from older notes and never landed.

  2. *Forgot dry-run.* `wraith fix` alone is the dry-run. If you
     skip it and pass `--apply` immediately you may be surprised
     by the breadth of edits. Always dry-run first.

  3. *Public API item flagged dead.* If you intentionally export
     something for downstream consumers, wraith flags it because
     it has no in-workspace caller. Add to `allow_dead` in
     `.wraithrc.json` BEFORE the next `--apply`.

  4. *Tests / examples imported the "dead" item.* Wraith follows
     references but a behind-feature-flag test path may not be
     analyzed. After `--apply` run `cargo check --all-targets`
     to catch resurrected-by-test breakage.

  5. *Forgot to commit the baseline.* Mixing other in-flight
     changes into the `--apply` diff makes review impossible.
     Always commit clean, then apply, then commit the cleanup.

  6. *Re-ran `--apply` without re-reading dry-run.* Source moves
     between runs. Always start each fix session with =wraith
     fix= dry-run on the current tree.

  7. *Removed a dep that's only used via cfg.* Items behind
     `#[cfg(feature ` "x")]= sometimes get classified as
     unused if the feature isn't enabled in the default build.
     Compile with the relevant features before trusting the
     unused-deps list.

# Verification checklist

  - [ ] Tree clean before `--apply`
  - [ ] Dry-run output reviewed and obvious-keeps moved to `allow_dead` / `allow_unused_deps`
  - [ ] `cargo check --workspace --all-targets` passes after `--apply`
  - [ ] `cargo test --workspace` passes
  - [ ] Diff committed in small reviewable chunks
  - [ ] No accidental edits outside the dead-code / unused-deps surface (`git diff` scoped)

# See also

  - [overview](overview.md) — when to reach for wraith at all
  - [clean-up-a-rust-package](clean-up-a-rust-package.md) — the full sweep that surfaces findings
  - [boundary-enforcement](boundary-enforcement.md) — codify what should never be imported
  - [refactor-extract-fn](refactor-extract-fn.md) — for complexity issues fix doesn't touch
  - [slop-suppression-policy](slop-suppression-policy.md) — what to do about lint-escape findings
