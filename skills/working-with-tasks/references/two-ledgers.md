# Two ledgers: bd/beads vs the in-repo org board

A Workbooks project has two task systems for two different audiences. Using the
wrong one corrupts the other's assumptions. They are never crossed.

## Ledger A — bd / beads (platform / engine dev)

For work on the **platform itself**: the runtime/host engine, the `wbx` CLI,
toolkits, the desktop app — anything that outlives a single tenant repo or
spans many files.

- Backed by a **local Dolt database**. It is **NEVER in git** — `.beads/` is
  gitignored and untracked on purpose (a public-repo liability). bd's git
  auto-backup is intentionally disabled; **do not re-enable it**.
- `BOARD.org`, when present, is a **one-way generated mirror** of bd for human
  reading. **Never hand-edit it** — edits are overwritten and never flow back.
- Core commands:
  ```sh
  bd ready                 # available work
  bd show <id>             # view an issue
  bd update <id> --claim   # claim it
  bd close <id>            # complete it
  bd prime                 # full workflow context + session-close protocol
  ```

## Ledger B — the in-repo org board (tenant / artifact work)

For a **tenant artifact's own agent** — e.g. a self-building site that schedules
its own work. The board lives **in the repo** as an org outline; the work *is*
the artifact.

- Tasks are org headings carrying `:TASK:` and a state (TODO/DOING/DONE-style
  keywords). The **workflow engine parses the headings** and drives the loop
  off their states — a native org outline IS the workflow (TODO keywords are
  states, nesting is sub-workflows, properties are edges/gates).
- Claiming is `:AGENT: <you>` on the node + a commit. State changes by *moving*
  the keyword, never deleting the node.
- This board IS committed to the tenant repo (unlike bd).

## The rule

| You are working on… | Use |
|---|---|
| runtime/host, CLI, toolkits, desktop, cross-repo platform work | **bd** |
| a tenant site/app's own scheduled agent work | **the in-repo org board** |

Never file platform work on a tenant board, and never put tenant-artifact tasks
in bd. If you're unsure which you're in, the `getting-started` repo-shape
detection tells you (platform repo → bd; tenant repo → org board).
