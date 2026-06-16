# Asana connector — sync a project into a Board
0.1.0
Stand up the config-gated :beam sync daemon that mirrors an Asana project into an org-native Board.

# When to use this
NETWORK: yes

  You want an Asana project mirrored into an org-native Board so the
  orchestrator can drive its tasks, or so you can query its tasks
  alongside everything else in the Context Tree.

# Workflow — how the sync runs
  The sync is NOT something an agent starts. It is a config-gated
  `:beam` GenServer under the engine supervisor — the deployment turns
  it on, never the agent (SERVICEHOST-PLAN.org trust floor). The
  `sync.org` node in this toolkit DECLARES the daemon; the DeployKit
  federation walk registers it when the connector is installed.

  The deploy env contract (set by the operator / DeployKit, NOT by you):

  One JSON env, `WB_CONNECTOR_SPECS`, carries the whole contract — a list
  of specs, one per installed connector (multi-connector: Asana and Linear
  sync side by side without sharing scope or creds). Presence is the gate.

```
  WB_CONNECTOR_SPECS=[{"type":"asana","scope":"<project-gid>",
    "ownership":"tenant","env_keys":["ASANA_PAT"],
    "interval_ms":60000}]
```

  `scope` is the LIST scope (the Asana project gid to mirror); `ownership`
  is the daemon tenancy `session/tenant/engine` (from =sync.org
  :OWNERSHIP:=). DeployKit emits this from the deployment's
  `:CONNECTOR_*:` props + toolkit manifests; you set nothing.

# What you get
  On each interval the engine pulls tasks changed since the last cursor
  (via Asana's `modified_since`), projects each onto the universal
  `:task:` map, and upserts a `:task:` headline matched on
  `(:SOURCE:, :REMOTE_ID:)`. Reconcile is last-writer-wins on
  `modified_at`, so a re-pull never clobbers a newer local edit and
  never duplicates.

  The mirror is pull-only: the Board owns execution state in-process and
  never touches the Asana API — completing a mirrored `:task:` does NOT
  push anything back. Outbound mutations exist only as explicit
  `TaskSync.push` verbs (create/update/delete; deletes Workgate-gated).

# Querying without the daemon
  You don't need the daemon to READ. Register the data-source plugin and
  query `asana-task` over OQL directly — pull-on-demand, no resident
  process. The daemon is only for a persistent mirror.

# Gotchas
  - `scope` is the Asana *project gid* to mirror — Asana's
    `GET /tasks` needs a project (or a `workspace:<gid>` scope). Set it to
    the project you want pulled, NOT an ownership level. The daemon
    tenancy rides the SEPARATE `ownership` field.
  - The mirror never mutates Asana on Board completion — there is no
    automatic write-back loop. Use the explicit push verbs if you need
    outbound changes.
  - Config-gated, NOT agent-startable: only the deployment
    (`WB_CONNECTOR_SPECS`) turns it on (the ServiceHost trust floor) — an
    agent can never spin up an in-engine `:beam` sync.
  - First-party ` `:beam= (in-engine, no extra machine); an untrusted
    community connector would run `:sandbox` (a pinned machine) — a
    separate, deferred path.

# See also
  - `overview` — what the connector is + the org `:task:` node shape.
  - `runtime/docs/BACKEND-PATTERN.org` — the #+KIND ladder + the airgap.
