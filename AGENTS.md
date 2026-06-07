# Agent Instructions

The single, tool-agnostic instruction file for any AI coding agent on this project.

## Four Golden Rules of Development

Consider these at **every turn**, before writing or accepting any code:

1. **DRY** — Is this code DRY enough? No copy-paste of logic that should have one home.
2. **Least code** — Is this written in the fewest lines of code possible? Prefer deleting and leaning on deps over adding.
3. **Componentize** — Can this be shared across multiple consumers instead of rewritten? Reduce duplication by increasing the dependency on one well-factored component, not by re-implementing.
4. **Drift** — Do we have drift, and is that drift causing the issue right now? Fix it by aligning around the right idea, not by patching around the wrong one.

## Issue Tracking (bd / beads)

This project uses **bd** (beads) for task tracking — not TodoWrite, markdown TODO lists, or `MEMORY.md`. The `.beads/` data is local and git-ignored; sync is via `bd dolt push/pull` (`refs/dolt/data` on the remote), separate from your code on `refs/heads/*`.

```bash
bd ready                 # find available work
bd show <id>             # view an issue
bd update <id> --claim   # claim work
bd close <id>            # complete work
bd prime                 # full workflow context + session-close protocol
```

## Non-Interactive Shell

Always pass non-interactive flags — `cp`/`mv`/`rm` may be aliased to `-i` and hang waiting on a y/n prompt.

```bash
cp -f source dest        # mv -f, rm -f, rm -rf, cp -rf
ssh/scp -o BatchMode=yes
apt-get -y               # brew: HOMEBREW_NO_AUTO_UPDATE=1
```

## Session Completion

Work is **not** complete until `git push` succeeds. Before ending a session:

1. File issues for any follow-up work.
2. Run quality gates if code changed (tests, linters, build).
3. Update issue status — close finished, update in-progress.
4. Push: `git pull --rebase && git push` — `git status` must show up-to-date with origin.
5. Hand off — leave context for the next session.

Never stop before pushing; never say "ready to push when you are" — you push.
