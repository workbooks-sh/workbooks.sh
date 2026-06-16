# The find → claim → do → record → hand-off protocol

The general loop a coding agent runs against either ledger. Commands differ by
ledger (see `two-ledgers.md`); the discipline is identical.

## 1. ORIENT — bounded

Read the board and your own log. Trust resume state instead of re-deriving it.
**Hard-cap your reads** — orientation that consumes the context window ships
nothing. Read enough to pick one task, no more.

- bd: `bd ready`, `bd show <id>`.
- org board: read the outline + your last log line.

## 2. FIND → CLAIM

Take the first unclaimed task in your lane/state, or the top open task by
priority.

- **Claim before working.** A peer-claimed task is invisible to you.
  - bd: `bd update <id> --claim`.
  - org board: set `:AGENT: <you>` on the node and commit the claim.

## 3. DO — the smallest shippable unit

Implement the least that satisfies the task. New ideas you spot become a **new
`** TODO`** (org) or a **new bd issue** — never a side note that gets lost.

## 4. SELF-VERIFY — tightest tier

Prove it at the cheapest tier that proves it; never await CI:

- workbook/content artifact → `workbook check` / `work content check`.
- runtime/engine → `mix compile` then `mix test` (targeted suite when possible).
- toolkit → `work toolkit verify <id>` then `eval`.

Re-read the change after.

## 5. RECORD — move state, don't delete

In the **same commit** as the work:

- Move the task to its next state (don't delete the node / don't drop the
  issue). bd: `bd close <id>`.
- Clear `:AGENT:` on an org node.
- One dated log line.
- A typed, stranger-readable commit message.

## 6. HAND OFF / CLOSE THE LOOP

- A run that changed nothing → a `NO-WORK` handoff line (but still commit any
  file you wrote).
- **Work isn't done until pushed AND live-confirmed** — fetch the served
  artifact and check it; don't trust the commit alone.
- **File follow-up issues before stopping.** The canonical failure is stopping
  with an unfiled blocker, or mislabeling a missing capability as "gated"
  without verifying the real blocker.
