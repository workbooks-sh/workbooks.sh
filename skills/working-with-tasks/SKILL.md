---
name: working-with-tasks
description: How a coding agent discovers and works the task board on a Workbooks project. Distinguishes the TWO ledgers — bd/beads for platform/engine dev vs the in-repo org BOARD (`:TASK:` front-matter) for tenant artifacts — and gives the general find → claim → do → record → hand-off protocol. Use when looping or scheduled, when multi-step work risks collisions, or when a board already exists. For a one-off human instruction, just act — but still FILE an issue for any follow-up you spot.
---

# Working with tasks

Two ledgers exist on this platform and they are never crossed. Pick the right
one first, then run the protocol.

## 1. Pick the ledger

| Work kind | Ledger |
|---|---|
| Platform / engine (runtime/host, CLI, toolkits, desktop) | **bd / beads** — local Dolt db, **NEVER in git**. `BOARD.org` is a one-way generated mirror; never hand-edit it. |
| Tenant / artifact (a self-building site's own agent) | the **in-repo org board** — `:TASK:` + state front-matter; the workflow engine parses the headings. |

Never cross them. The full split is `references/two-ledgers.md`.

## 2. Decide discover-vs-act

Look for a task when you are **scheduled/looping**, the work is **multi-step
with shared files**, or **a board already exists**. Just act on a direct
one-off or a sub-minute fix — but still **file follow-ups** for anything you
spot. (The canonical failure here is stalling and mislabeling a missing
capability as "gated" instead of filing an issue — verify the real blocker
first.)

## 3. Front-matter vs a separate file

- Task lives **in the org board** when the workflow engine drives the loop off
  its states and the work *is* the artifact.
- Stable cross-run knowledge (laws / method / tokens / search discipline) →
  a **separate skill or board file**, not a task.
- **bd** → when work spans many files or must outlive a single tenant repo.

Decision detail: `references/front-matter-vs-skill-file.md`.

## 4. The protocol (find → claim → do → record → hand off)

The full version with bd and org-board commands is `references/protocol.md`.
The shape:

1. **ORIENT (bounded).** Read the board + your own log; trust resume state;
   hard-cap reads — orientation that eats the context window ships nothing.
2. **FIND → CLAIM.** First unclaimed task in your lane/state (or top open by
   priority; bd: `bd ready`). **Claim before working** — set `:AGENT: <you>` +
   commit a claim, or `bd update <id> --claim`. A peer-claimed task is
   invisible to you.
3. **DO the smallest shippable unit.** New ideas → a new `** TODO`, never side
   notes.
4. **SELF-VERIFY** at the tightest tier (`work content check` / `mix compile` +
   `mix test` / build); re-read the change.
5. **RECORD by moving state, not deleting**, in the same commit; clear
   `:AGENT:`; one dated log line; a typed, stranger-readable commit; `bd close
   <id>`.
6. **HAND OFF / CLOSE LOOP.** A no-change run → `NO-WORK` handoff (but commit
   any file you wrote). Work isn't done until **pushed AND live-confirmed**
   (fetch the served artifact). File follow-up issues before stopping.

## References

- `references/two-ledgers.md` — bd/beads vs the in-repo org board, in full.
- `references/protocol.md` — the find→claim→do→record→hand-off commands for both ledgers.
- `references/front-matter-vs-skill-file.md` — where a piece of knowledge belongs.
