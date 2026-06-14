# linear

A federation toolkit that mirrors a Linear project or team into the workbook as org `:task:` nodes. The agent's Board reads issue headlines off disk and never touches Linear's API — a sync daemon does the external I/O with the tenant's credentials, on an interval, as a supervised process in the runtime.

## When to reach for it

Add `linear` when a workbook needs Linear issues inside its own task board — so an agent can plan, query, and (when gated) write back against real Linear work without the Board ever holding the API key or making live calls.

## Example

```
# bind the team/project once (creds via the runtime's plugin auth)
# then query the synced :task: nodes as a data source:
SELECT title, state FROM linear-issue WHERE assignee = 'me'
```

## What it grants

- A read face: `SELECT ... FROM linear-issue` routes to Linear through the plugin's OQL data-source.
- A supervised sync daemon that pulls issues into `:task:` org nodes on an interval (BEAM GenServer, no microVM).
- Gated write-back to Linear.
- An airgap: the Board only sees org headlines on disk; the connector alone touches `LINEAR_API_KEY`.

## Maturity

Experimental. Requires `LINEAR_API_KEY`, fetched through the runtime's plugin auth (never `System.get_env` directly — toolkits hold no creds).
