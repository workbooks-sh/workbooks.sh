# asana

A federation toolkit that mirrors an Asana project into the workbook as org `:task:` nodes. The agent's Board reads task headlines straight off disk and never touches Asana's API — a sync daemon does all the external I/O with the tenant's credentials, on an interval, as a supervised process in the runtime.

## When to reach for it

Add `asana` when a workbook needs Asana work to show up inside its own task board — so an agent can plan, query, and (when gated) write back against real Asana issues without the Board ever holding Asana credentials or making live API calls.

## Example

```
# bind the project once (creds via the runtime's plugin auth, not env directly)
# then the synced :task: nodes are queryable as a data source:
SELECT title, status FROM asana-task WHERE assignee = 'me'
```

## What it grants

- A read face: `SELECT ... FROM asana-task` routes to Asana through the plugin's OQL data-source.
- A supervised sync daemon that pulls the project into `:task:` org nodes on an interval (BEAM GenServer, no microVM).
- Gated write-back to Asana.
- An airgap: the Board only ever sees org headlines on disk; the connector alone touches `ASANA_PAT`.

## Maturity

Experimental. Requires `ASANA_PAT`, fetched through the runtime's plugin auth (never `System.get_env` directly — toolkits hold no creds).
