# linear — sync daemon spec

Status: experimental

## About

Face 3 of 3 of the `linear` federation toolkit: the sync daemon
declaration. The DeployKit federation provision walk (wb-gi9i.8) reads
this node to register the connector's interval pull when the toolkit is
installed on a deployment that can host a `beam` daemon.

`RUNTIME: beam` + `OWNERSHIP: tenant`: a first-party, signed-into-the-
image connector runs IN the engine as a supervised GenServer
(`WorkbooksRuntime.Plugin.TaskSync`) — no VMM, no sandbox, no separate
process. The trust floor (SERVICEHOST-PLAN) permits `beam` ONLY
for deployment-manifest / first-party daemons; an agent could never
start this.

## linear-sync (daemon)

- **ID:** linear-sync
- **RUNTIME:** beam
- **OWNERSHIP:** tenant
- **DIRECTION:** pull
- **INTERVAL_MS:** 60000
- **IMPL:** WorkbooksRuntime.Plugin.TaskSync
- **ADAPTER:** WorkbooksRuntime.Plugin.Linear
- **ENV_KEYS:** LINEAR_API_KEY
- **CAPABILITY:** connector.task.sync
- **NETWORK:** yes

Interval pull: list Linear issues changed since the last cursor →
project onto the universal `task` map → upsert `task` nodes
matched on `(SOURCE, REMOTE_ID)`. `DIRECTION: pull` is the safe
read-only default; write-back (create/update/delete/comment) is a
synchronous call, with DESTRUCTIVE deletes gated through a Workgate
permit (`connector.task.delete`).

No automatic completion loop (cf2 board-authoring-only): the Board owns
execution state in-process and never calls a connector when a task
completes — the mirror is pull-only. Outbound mutations exist only as
explicit `TaskSync.push` verbs (create/update/delete, deletes gated by
the Workgate permit above); the airgap holds in both directions.
