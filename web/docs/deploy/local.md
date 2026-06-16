
# Deploy the runtime locally

> Bring the Workbooks runtime up on your own machine with a container engine.

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:82
- **OWNER:** cli

`wbx deploy` is the **user** tool for running the runtime image for your own use —
not a platform-release mechanism. Locally it converges `deployment.org` against a
container-engine seam: `docker`, `podman`, or `krunvm` (whichever is on PATH).

```bash
wbx deploy local        # scaffold ./deployment.org if absent, then apply
```

## Step by step

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:32
- **SRC:** cli/src/deploy/mod.rs#DeployVerb

1. `wbx deploy init local` — scaffold `deployment.org`.
2. `wbx deploy secrets set KEY=VALUE` — store declared secrets (0600, under the app
   dir; never written into `deployment.org` or any image).
3. `wbx deploy validate` — coherence check, including declared-but-unset secrets.
4. `wbx deploy apply` — converge to the declared state.
5. `wbx deploy status` / `wbx deploy logs` — inspect / tail.
6. `wbx deploy down` — tear it down.

`wbx deploy doctor` reports which engines, recipes, and secrets are present.

## krunvm caveat

- **MATURITY:** partial
- **EVIDENCE:** cli/src/deploy/mod.rs:471
- **CAVEAT:** krunvm can't deliver the kit's secrets env yet — use docker/podman locally, or a cloud provider, when secrets are required.

The full reference for every verb and flag lives in [Reference → Deploy & kernel](../reference/deploy.md).
