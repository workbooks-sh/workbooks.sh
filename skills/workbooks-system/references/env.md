# Environment variables the runtime reads

Every `WB_*` (and a few related) env var the runtime host code reads, grouped by
subsystem, with its default and purpose. Secrets always come from ENV, never from
a config file (`deployment.org` / `publish.org`). A deployment converges most of
these from the config (`Config.to_env` maps `STORAGE`/`DATABASE`/`PROFILE`/etc.
onto the right `WB_*`), so you rarely set them by hand for a managed deploy.

TOC: planes/boot · tenancy/auth · storage/database · models/embeddings · agent
execution · keeper/lifecycle/dreams · toolkits · deploy/image · client target ·
identity/vars/misc

## Planes & boot

| Var | Default | Purpose |
|---|---|---|
| `WB_WEB` | unset | `=1` starts the control plane (`Workbooks.Web`) on `PORT` (4000) |
| `WB_PUBLIC` | unset | `=1` starts the content plane (`Workbooks.PublicWeb`) on `PUBLIC_PORT` (4001) |
| `WB_PUBLIC_TLS` | unset | `=1` serves the content plane over HTTPS with per-host SNI certs |
| `WB_DESKTOP` | unset | `=1` runs the desktop daemon: control plane on all interfaces at the fixed desktop port + writes the discovery file + a per-boot token |
| `WB_DESKTOP_DIR` | — | override the desktop support directory (discovery file location) |
| `WB_DATA` | `tmp/data` | the data volume root — repos, ledgers, keeper cadence files, public site dir |

## Tenancy & auth

| Var | Default | Purpose |
|---|---|---|
| `WB_TENANCY_MODE` | `single` | `single` | `multi`; multi-tenant rejects spoofable `x-tenant` |
| `WB_TENANT` | `local` | the tenant for shared-secret/keeper runs |
| `WB_PRIMARY_TENANT` | `dev` | the tenant the stable signing key applies to |
| `WB_PUBLIC_BEARER` | unset | shared-secret lock for cloud deploys; set → bearer required, no dev fallback |
| `WB_AUTH_ISSUER` | `betterauth` | the JWT issuer for the production auth path |
| `WB_AUTH_SECRET` | — | the BetterAuth/Guardian signing secret |
| `WB_JWKS_URL` | — | JWKS endpoint for verifying production JWTs |

## Storage & database

| Var | Default | Purpose |
|---|---|---|
| `WB_STORAGE` | `local` | blob backend: `local` (volume) | `s3` | `r2` |
| `WB_S3_KEY` / `WB_S3_SECRET` | — | S3/R2 credentials (SigV4); secrets, ENV only |
| `WB_S3_*` | — | bucket/endpoint/region for the S3 adapter |
| `WB_DATABASE_URL` | — | Postgres DSN (multi-tenant cloud); secret, ENV only |
| `WB_PG_HOST` | `localhost` | local Postgres host |
| `WB_PG_PORT` | `5433` | local Postgres port |
| `WB_PG_DB` | `workbooks` | local Postgres database name |
| `WB_PG_USER` | `postgres` | local Postgres user |
| `WB_PG_PASS` | `` (empty) | local Postgres password |

## Models & embeddings

| Var | Default | Purpose |
|---|---|---|
| `WB_LLM_KEY` | — | the LLM provider API key (agent + judge runs) |
| `WB_LLM_MODEL` | `xiaomi/mimo-v2.5` | the default agent model |
| `WB_EVAL_MODEL` | — | the model for the LLM-judge eval tier (Tier 2) |
| `WB_THOUGHT_MODEL` | `x-ai/grok-build-0.1` | model for the public-plane "thought" narration |
| `WB_DREAM_MODEL` | `inception/mercury-2` | the small model that writes dream/daydream entries |
| `WB_EMBED` | `hash` | text embedder: `hash` (deterministic) | `clip` | `http:<url>` |
| `WB_EMBED_MODEL` | (provider default) | the embedding model id |
| `WB_EMBED_KEY` | — | the embedding provider key |
| `WB_EMBED_DIM` | `1536` / `256` | embedding dimensionality (provider-dependent) |
| `WB_EMBED_MULTIMODAL` / `WB_EMBED_IMAGE` / `WB_EMBED_VIDEO` | — | per-modality embedders (`http:<url>` / `clip`) |
| `WB_MODELS_DIR` | `/opt/models` | where models baked into the image live |

## Agent execution

| Var | Default | Purpose |
|---|---|---|
| `WB_AGENT_EXEC` | unset | `=1` grants the real-CLI `run` escape hatch (trusted agents only; never multi-tenant) |
| `WB_RUN_TOOL_TIMEOUT_MS` | `120000` | wall-clock bound for the `run` escape-hatch tool |
| `WB_PROFILE_DIR` | — | directory of canonical profile `:agent:` defs baked into the image |

## Keeper / lifecycle / dreams

| Var | Default | Purpose |
|---|---|---|
| `WB_KEEPER_DEF` | unset | path to an Org agent def; **required** to activate the keeper (else idle) |
| `WB_KEEPER_INTERVAL_MS` | `3600000` (1h) | tick interval |
| `WB_KEEPER_MODE` | `plan` | `plan` (critique + backlog only) | `edit`; passed into the task line |
| `WB_KEEPER_RUN_TIMEOUT_MS` | `900000` | wall-clock bound per keeper tick |
| `WB_KEEPER_CONTINUOUS` | unset | `=1` near-continuous mode — short breather between ticks instead of the fixed interval |
| `WB_KEEPER_BREATHER_MS` | `45000` | the breather length in continuous mode |
| `WB_LIFECYCLE_DEF` | unset | path to a lifecycle state-machine spec; unset → the keeper's env+prose fallback |
| `WB_DREAM_MIN_INTERVAL_MS` | `3000000` (~50m) | minimum time between full dreams |

## Toolkits

| Var | Default | Purpose |
|---|---|---|
| `WB_TOOLKITS_ROOT` | `toolkits/` or `../toolkits/` | discovery root (honored only if it's an existing dir) |
| `WB_TOOLKIT_EXEC` | unset | `=1` opts into running `:role` bash blocks (verify/eval/run), sandboxed + capped. Default-deny |

## Deploy / image

| Var | Default | Purpose |
|---|---|---|
| `WB_IMAGE` | — | the runtime image ref a deployment runs (passed to providers) |
| `WB_REGISTRY` | `:memory:` | the command/package registry store |
| `WB_CONTAINER_RUNTIME` | `docker` | container backend; `podman`/`krunvm` are drop-in |
| `WB_CONTAINER_IMAGE` | — | the container image to run |
| `WB_COMPILERS_IMAGE` | — | override the compilers-layer reference the image `COPY --from`s |
| `WB_PLATFORMS` | `linux/amd64,linux/arm64` | buildx target platforms |
| `WB_INSTALL_URL` | `https://workbooks.sh/install.sh` | the desktop installer URL (`wbx desktop install`) |

## Client target (CLI → running runtime)

| Var | Default | Purpose |
|---|---|---|
| `WB_RUNTIME_URL` | unset | explicit runtime URL for `wbx rt`/`wbx ctk`/`wbx dev`; else the local discovery file |
| `WB_TOKEN` | `` (empty) | the bearer for `WB_RUNTIME_URL` |

## Identity / vars / misc

| Var | Default | Purpose |
|---|---|---|
| `WB_SIGNING_KEY` | — | base64 of the 32-byte Ed25519 seed — keeps the engine's DID stable across deploys; secret |
| `WB_VARS` | `:memory:` | the variable-store backend |
| `WB_PM_DBG` | unset | package-manager debug logging |

Model-key discovery for `wbx dev info` also recognizes these (not `WB_*`):
`OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`,
`GOOGLE_API_KEY`; publishing reads `CLOUDFLARE_ACCOUNT_ID`.
