# Deploy Kit — `work deploy` (the USER tool to run a runtime)

`work deploy` is for **consumers of our CLI** who want to run the Workbooks
runtime image for their own use. It is NOT a platform-release mechanism — see
`release-three-layers.md`. Never wire compiler/runtime-image publishing into it.

## Container model

ONE OCI image. Local and cloud are the SAME image:

- **Local** — the same image in a Linux container, mac-first behind a
  `krunvm | podman | docker` seam. NOT microVM sandboxes.
- **Cloud** — the same image on Fly (or the user's target), pushed to a registry
  **the user controls** via `WB_IMAGE`.

## Verbs (user-facing)

| Verb | Purpose |
|---|---|
| `work deploy init`     | scaffold the deploy config |
| `work deploy validate` | check the config before applying |
| `work deploy apply`    | stand up / update the runtime |
| `work deploy update`   | roll to a new image |
| `work deploy verify`   | confirm health of the deployed runtime |
| `work deploy status`   | current state |
| `work deploy logs`     | stream logs |
| `work deploy down`     | tear it down |
| `work deploy local`    | prod-parity run of the same image in a krunvm container |

`build` / `publish` exist but push to a registry the **user** controls — not our
ghcr packages.

## Redeploy-while-live

Redeploy anytime; killing brand/board runs freely is allowed (the old "no
redeploy while a run is live" rule is lifted). Fail fast in dev.

## What `work deploy` is NOT

- Not how the platform publishes the compilers package (manual, own ghcr).
- Not how the platform builds the runtime image (CI, on push to main).
- See `release-three-layers.md` — keep the three layers apart.
