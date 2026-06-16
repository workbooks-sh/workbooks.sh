# Deploy Kit — running, operating, and extending your own runtime

Deploy Kit is how you get a workbooks runtime of your own: locally for
development, or on your own infrastructure for production. One OCI image is
the unit of deployment everywhere — local is the SAME image in a Linux
container, not a different stack.

## The shape of a deployment

- **One image** (the runtime: BEAM + wasmtime + the release). You point at
  the published image or push it to your own registry via `WB_IMAGE`.
- **One durable volume** (the data dir, `WB_DATA`): the registry database,
  tenant git repos, published site trees, agent state. Machines are
  disposable; the volume is the deployment.
- **Two planes** on every engine:
  - public content plane — exposed port, anonymous, GET-only. Serves
    published workbooks/sites plus the public feeds (`/_changes` — the
    tenant's commit log; `/_activity` — live agent telemetry when an agent
    is hosted).
  - control plane — internal port, every write, authed with a bearer token.
    Keep it off the public internet; reach it through your platform's
    private networking or tunnel.

## The verbs

```
work deploy init       # scaffold a deployment config
work deploy validate   # check it before touching anything
work deploy apply      # create/update the deployment
work deploy update     # roll a new image/config
work deploy verify     # prove the engine is actually serving
work deploy status     # what's running where
work deploy logs       # engine logs
work deploy down       # tear down
```

Local target runs the image in a container (krunvm/podman/docker behind one
seam); cloud targets deploy the same image to your provider. Prod-parity
testing is `work deploy local` — same bytes that ship.

## Talking to a deployed engine from the CLI

Engine-targeted commands resolve the engine from the environment:

```
WB_ENGINE_URL=<control plane url>  WB_ENGINE_TOKEN=<bearer>  work workbook list
```

Operate content with `work workbook deploy/list/show`, capabilities with
`work toolkit …`, configuration with `work var …`. Prefer these over shelling
into machines: CLI operations go through the authed control plane, are
logged as commits on the tenant's git rail, and work identically against
local and cloud engines. SSH into a box is for diagnosing the box, not for
operating the platform.

## Environment contract (the knobs an engine reads)

| Variable | Meaning |
|---|---|
| `WB_DATA` | durable data dir (volume mount) |
| `WB_REGISTRY` | registry database path |
| `WB_TENANT` | the tenant whose git repo is the engine's changelog |
| `WB_WEB`, `PORT` | control plane on/port |
| `WB_PUBLIC`, `PUBLIC_PORT` | public plane on/port |
| `WB_PUBLIC_BEARER` | control-plane bearer token |
| `WB_KEEPER_DEF` | org agent definition → activates the resident agent |
| `WB_KEEPER_INTERVAL_MS` / `WB_KEEPER_CONTINUOUS` / `WB_KEEPER_BREATHER_MS` | agent cadence: fixed interval, or always-on with a short breather |
| `WB_KEEPER_RUN_TIMEOUT_MS` | wall-clock kill for a wedged run |
| `WB_LIFECYCLE_DEF` | org lifecycle state machine (wake/audit/rem states) |
| `WB_DREAM_MODEL`, `WB_DREAM_MIN_INTERVAL_MS` | the dreaming side-process |
| `WB_LLM_MODEL`, `OPENROUTER_API_KEY` | default model + key for agent runs |

Secrets go in the platform's secret store, never in the tenant repo (tenant
repos are typically public — they are the changelog).

## Hosting agents on an engine

A resident agent is LOADED configuration, not code: an org def
(`WB_KEEPER_DEF`), optionally a lifecycle spec (`WB_LIFECYCLE_DEF`), a board
(`plan.org` in the tenant repo), and skills. The scheduler runs the def on
its cadence; every level of execution is wall-clock bounded; agent commits
land on the tenant git rail and surface publicly at `/_changes`. To change
agent behavior on a live engine, update the LOADED org files — never patch
host code for it.

## Extending the runtime

- New capabilities for agents/workbooks → build a toolkit (WASM commands +
  skills); see `toolkit.md`. Hot-swaps onto a live engine.
- New host behavior (planes, schedulers, engines) → host code, shipped only
  through a new runtime image and a rolling deploy.
- Providers: the UI/host capability seam routes each capability to a
  provider (local OS, a runtime server, or the in-process kernel). A
  deployment target is a routing config, not a code fork — extend by adding
  providers behind the seam, never by forking the surface.
