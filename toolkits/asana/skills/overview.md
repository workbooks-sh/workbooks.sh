# Asana connector — overview
0.1.0
Federate an Asana project into org :task: nodes the Board can drive; query via OQL; gated write-back.

# When to use this
  First contact with the Asana connector. Reach for it when you want an
  Asana project's tasks to appear as Workbooks `:task:` nodes the
  orchestrator Board can drive, or when an agent needs to query/update
  Asana. To set up the live mirror, read `sync-a-project`.

# What this connector does
  Asana is a task tracker. This toolkit federates Asana into the
  Workbooks runtime: it mirrors an Asana project's tasks into org
  `:task:` nodes the orchestrator Board can drive, and (when write-back
  is enabled) pushes Board changes back to Asana.

  The mirror is one-directional by default (`:pull`, read-only). Pull is
  always safe: it only writes `:task:` headlines on disk. Write-back is
  opt-in and DESTRUCTIVE deletes are gated through a Workgate permit.

# Common verbs
  - *Read via OQL* — once the data-source plugin is registered you can
    query Asana tasks directly:

```sql
      SELECT title, state, assignee FROM asana-task WHERE state = 'done'
```

  - *Mirror into a Board* — the sync daemon (`sync.org`) pulls on an
    interval into a federation board. See `sync-a-project`.

  - *Write back* — Board task changes push to Asana when write-back is
    enabled; destructive deletes go through a Workgate permit (fail-closed).

# Credentials
  Set `ASANA_PAT` (an Asana personal access token) in the engine's env /
  `wb env` keychain. The connector reads it through
  `WorkbooksRuntime.Plugin.Auth`; it is never stored in this toolkit. The
  REST API authenticates with a `Bearer` token.

# What the org :task: node looks like
  A pulled task becomes a `:task:`-tagged headline whose drawer carries
  the universal field set plus the identity drawer:

```org
  ** Draft the launch email                                       :task:
     :PROPERTIES:
     :ID:        asana-1201
     :STATE:     ready
     :SOURCE:    asana
     :REMOTE_ID: 1201
     :UPDATED:   2026-06-03T12:00:00.000Z
     :ASSIGNED_TO: alice
     :END:
     Task notes become the task description.
```

  `Loader.Org` loads this as an ordinary Board task — the airgap proof.

# Common pitfalls
  - Asana has NO rich state enum: `completed: true` → `:done`, otherwise
    `:ready`. Don't expect backlog/in-progress/review distinctions to
    survive the round-trip — Asana doesn't carry them at the task level.
  - The mirror is `:pull` (read-only) by DEFAULT — write-back is opt-in.
  - There is NO `asana` CLI: this is a SaaS federation connector
    (`plugin/` + `sync.org`), NOT a CLI-wrapper toolkit — so the manifest
    declares no `#+CLI_BIN:`.
  - Deletes fail closed: a denied or absent Workgate permit blocks the op.

# See also
  - `sync-a-project` — set up the interval mirror into a Board.
  - `runtime/docs/BACKEND-PATTERN.org` — the #+KIND ladder + the org-`:task:` airgap.
