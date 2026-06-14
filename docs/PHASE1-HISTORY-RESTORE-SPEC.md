# Phase 1 spec — History + Restore (for sign-off)

*Date: 2026-06-14. First build slice of `COLLABORATIVE-WORKSPACES-DIRECTION.md`. Spec for founder sign-off — no code written yet. Scope is deliberately tiny: the headline promise "**nothing is lost, restore anything**" with almost pure wiring of primitives that already ship.*

## What the user gets (our vocabulary only)
- A **History** panel on a nexus (and later a workbook): a reverse-chron list of **Changes**.
- Each Change shows, in plain language: a **title** (what changed), **who** (You · a teammate by name · an agent by name), **when**, and an expandable **before → after**.
- **Restore**: on any past Change, a "**Restore this version**" button → a confirm → the content returns to that version, and a new entry appears: *"Restored to the version from June 3."* Nothing is deleted.
- **Zero git words.** No commit/branch/diff/HEAD/sha shown — only Change, History, Restore, before/after.

```
History — aurora
┌───────────────────────────────────────────────┐
│ ● now      You          Renamed the homepage   │
│ ○ 2h ago   Waldo (agent) Added pricing section  ▸ before/after │
│ ○ 1d ago   Maya Chen     Fixed the contact form │
│ ○ 3d ago   Waldo (agent) Initial build          │
│            ⟲ Restore this version               │
└───────────────────────────────────────────────┘
```

## Engine mapping (invisible plumbing)
| User concept | Built on | Status |
|---|---|---|
| The timeline | `Git.log_entries` (already feeds `/_changes`, `web.ex:1022`) | ✅ exists |
| before → after | `Git.diff/1` (`git.ex:358`) — **currently unwired**, expose it | new endpoint |
| who = You/teammate/agent | commit author; agent commits carry the agent's identity; bridge the workspace member name | partial (agent vs human now; named-member later) |
| Restore | append-only forward re-apply (read old tree → write working copy → new commit). NEVER `reset --hard` | new verb |
| undo of an agent action (next phase) | `jj op undo` (`jj.ex`, vendored) | Phase 2 |

## API (new, tenant-scoped per existing isolation rules)
- `GET /api/history/:scope` → `[{ id, when, authorType: "human"|"agent", authorName, title }]` (scope = nexus or workbook id; filtered by caller tenant, same guard as `/instances`).
- `GET /api/history/:scope/:id/diff` → `{ before, after }` (wraps `Git.diff/1`).
- `POST /api/history/:scope/restore` `{ to: <id> }` → append-only restore; returns the new Change. Ownership-checked.

Implementation note: put the logic in a **new `Workbooks.History` module** wrapping `Git` (log/diff/restore), so we touch `git.ex` minimally (add one `restore/2` that's a forward re-apply) and add ~3 thin routes to `web.ex`. *Coordinate `web.ex`/`git.ex` edits with the parallel session — commit in tight increments.*

## Dashboard UI
A **History** view in `web/cloud-dashboard` (a tab on the nexus detail, and/or a top-level route), rendering the timeline + per-change before/after + Restore, in the existing design system (cards, our fonts, dark/light). Reads the three endpoints above. Mock-first if the runtime endpoints aren't wired yet, then swap (same `api.js` pattern).

## Reuse vs new
- **Reuse:** `Git.log_entries`, `Git.diff/1`, the `/_changes` shape, the tenant-scope guards, the dashboard design system + `api.js` swap pattern.
- **New:** `Workbooks.History` module, `Git.restore/2` (append-only), 3 routes, the History UI, human/agent attribution mapping.

## Explicitly NOT in Phase 1
Shared folders (josh), Drafts/branches, multi-level RBAC, jj-undo, GitHub export, the per-line "who changed this line" view. Those are later phases. Phase 1 is *only* History + Restore.

## Verification
- Tenant-scoped: a caller can't read another tenant's history (extend `tenant_isolation_http_test`).
- **Restore is append-only**: a test that restoring an old version creates a NEW change and the prior history is intact (nothing erased).
- Human vs agent attribution renders correctly.
- e2e in the dashboard: open History → expand a change → Restore → the new entry appears.

## Open question carried in
Restore = append-only — assumed yes (the whole spec depends on it). Confirm before build.
