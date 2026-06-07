# wb-4qkt reconcile — profile deploy paths (proposal, 2026-06-05)

Resolved the deploy archaeology behind the profile drift. **No blind change made**
— this is the exact proposal for human approval (which Fly app is live is the
only open question).

## The three engine images

| Image | Profile source | Skill contract | Status |
|---|---|---|---|
| `deploy-kit/cloud/Dockerfile.engine` (lean) | none | — | breaks every harvest verb; not for brandnana |
| **`deploy-kit/cloud/Dockerfile.engine-profile`** | `COPY substrates/brandnana/profile /opt/profile` + `ENV WB_PROFILE_DIR=/opt/profile` | `/opt/profile/skills` | **CANONICAL & CURRENT** — used by `fly.bn-engine.toml` |
| `services/brandnana-agent/Dockerfile` | `COPY services/brandnana-agent/profile` → `/opt/brandnana-profile`; entrypoint stages `Engine/.` → `$DATA_ROOT/Engine/` | `Engine/skills` | **LEGACY** — profile is 422 lines stale (pre-Stage-2), only 6 files |

The canonical strategist (`substrates/brandnana/profile/agents/brandnana-strategist.org`)
reads skills via absolute `/opt/profile/skills/…` — which resolves ONLY under the
`engine-profile` image (`WB_PROFILE_DIR=/opt/profile`). The legacy `services`
strategist reads relative `Engine/skills` — a different, older contract.

## Diagnosis

`services/brandnana-agent` is the pre-cutover image. `wb-3uh3` ("cut over to the
Workbooks Engine on Fly.io, delete legacy CF agent code") is precisely the task
that retires it. The canonical path (`bn-engine` via `Dockerfile.engine-profile`)
already bakes the CURRENT `substrates/brandnana/profile`, so **all 13 iterations
of deck-v2 / analysis-gate / insight-slides work is already correct in the
canonical image** — it just needs to be the one that's deployed.

## The only open question (human/ops)

Which Fly app currently serves `api.brandnana.net` book runs?
- If **`bn-engine`** (the `fly.bn-engine.toml` app): the drift is already moot —
  production runs the current profile. Action: **retire `services/brandnana-agent`**
  (delete the dir + its stale profile) so the divergent copy can't mislead. Low risk.
- If **`services/brandnana-agent`** is still live: cut over. Deploy `bn-engine`
  (`Dockerfile.engine-profile`), repoint DNS/routing, then delete
  `services/brandnana-agent`. This is the wb-3uh3 cutover.

## Recommendation

Confirm `bn-engine` is the live app, then **delete `services/brandnana-agent/`
entirely** (Dockerfile + entrypoint + stale profile). The canonical
`Dockerfile.engine-profile` + `substrates/brandnana/profile` is the single source
of truth and is already current. Until then, do NOT sync the stale copy (it would
need the `/opt/profile/skills` vs `Engine/skills` contract reconciled — pointless
work on code that should be deleted).

## After reconcile

Run `projects/brandnana/scripts/run-book.sh tecovas.com` (wb-sxqs) against the
canonical engine and watch via `wb trace` — the §4 acceptance test on the real
deck-v2 pipeline.
