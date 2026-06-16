
# wbx deploy & the OCI image

> Reference for the Deploy Kit — `wbx deploy` verbs, deployment.org, the ONE runtime image, local vs cloud, and the OQL kernel WIT world.

- **OWNER:** deploy-kit
- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:31-110
- **SRC:** cli/src/deploy/mod.rs#DeployVerb

`Deploy Kit` is the USER tool: it runs the one runtime OCI image for **your own**
use — locally (a container) or in the cloud (a provider recipe). It is NOT how
the platform publishes the compilers package or the runtime image. The bootstrap
verb is special: it must run with NO runtime up — it is what *brings the runtime
up*, reading `deployment.org` and converging via container engine / provider
recipe. Native-only.

> The three release layers must not be conflated. Deploy Kit is layer 3 (users
> only). The compilers package (layer 1, published manually) and the runtime image
> (layer 2, built by CI) are NOT `wbx deploy`. See [Release layers](*Release layers (do not conflate)).

## Verbs

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:31-57
- **SRC:** cli/src/deploy/mod.rs#DeployVerb

The `DeployVerb` enum (clap subcommands) — `cli/src/deploy/mod.rs:31`.

| verb | does | src |
| --- | --- | --- |
| `wbx deploy init [preset]` | scaffold `./deployment.org`; preset `local` \vert `cloud` (TTY picks) | `cli/src/deploy/mod.rs:34,161` |
| `wbx deploy validate` | coherence check on `deployment.org` incl. declared secrets | `cli/src/deploy/mod.rs:40,152` |
| `wbx deploy apply` | converge to declared state (local container or provider recipe) | `cli/src/deploy/mod.rs:42,363` |
| `wbx deploy status` | inspect the live deployment | `cli/src/deploy/mod.rs:44,98` |
| `wbx deploy logs` | tail the live deployment's logs | `cli/src/deploy/mod.rs:46,99` |
| `wbx deploy down` | tear it down | `cli/src/deploy/mod.rs:48,100` |
| `wbx deploy local` | shorthand: scaffold local config if absent, then apply | `cli/src/deploy/mod.rs:50,101` |
| `wbx deploy doctor` | engines, recipes, declared secrets — present vs missing | `cli/src/deploy/mod.rs:52,527` |
| `wbx deploy secrets …` | manage kit-abstracted, provider-delivered secrets (subcommands) | `cli/src/deploy/mod.rs:54,223` |

Note: the binary is invoked `wbx` (`cli/src/main.rs:24`, `name = "wbx"`). Older
docs and source moduledoc comments still say `wb deploy`; the shipped command is
`wbx deploy`.

### deploy secrets subcommands

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:59-73
- **SRC:** cli/src/deploy/mod.rs#SecretsVerb

| verb | does | src |
| --- | --- | --- |
| `wbx deploy secrets set KEY=VALUE …` | stage KEY=VALUE pairs (or `--from-env <file>`) | `cli/src/deploy/mod.rs:61,225` |
| `wbx deploy secrets list` | list secret NAMES (never values) | `cli/src/deploy/mod.rs:65,251` |
| `wbx deploy secrets unset KEY` | remove a secret by name | `cli/src/deploy/mod.rs:67,258` |
| `wbx deploy secrets push` | push staged secrets to the provider without a deploy | `cli/src/deploy/mod.rs:71,266` |

Secrets are declared by NAME in `deployment.org` (`#+DEPLOY_SECRETS: KEY …`),
values staged via `secrets set`, stored `0600` at `<app-dir>/secrets.env`
(`cli/src/deploy/mod.rs:187,206-211`), and delivered per provider — env-file
locally, the recipe's `provider_set_secrets` hook in the cloud. Values never
enter `deployment.org` or images (`cli/src/deploy/mod.rs:18-21`).

## deployment.org — the shipped (CLI) keyword schema

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:114-145
- **SRC:** cli/src/deploy/mod.rs#Config

The shipped `wbx deploy` parses `deployment.org` as flat `#+KEYWORD:` lines
(`org_keywords`, `cli/src/deploy/mod.rs:149`). Recognized keys:

| keyword | default | meaning | src |
| --- | --- | --- | --- |
| `#+DEPLOY_TARGET:` | `local` (alias `PLACE:`) | `local` or a provider recipe name (e.g. `fly`) | `cli/src/deploy/mod.rs:117` |
| `#+DEPLOY_APP:` | `workbooks` (alias `APP:`) | app / container name | `cli/src/deploy/mod.rs:120` |
| `#+DEPLOY_REGION:` | `sjc` | cloud region | `cli/src/deploy/mod.rs:123` |
| `#+DEPLOY_IMAGE:` | `ghcr.io/workbooks-sh/runtime:latest` | OCI image (`WB_IMAGE` env overrides) | `cli/src/deploy/mod.rs:126,76` |
| `#+DEPLOY_PORT:` | `4000` | host + container port | `cli/src/deploy/mod.rs:132` |
| `#+DEPLOY_SECRETS:` | (none) | space-separated secret NAMES the deploy needs | `cli/src/deploy/mod.rs:136` |
| `#+DEPLOY_TOOLKITS:` | (none) | `id:dir id:dir …` pushed after a cloud apply | `cli/src/deploy/mod.rs:384` |

`WB_IMAGE` (env) always wins over =#+DEPLOY_IMAGE: =
(`cli/src/deploy/mod.rs:127-131`). The default image constant is
`ghcr.io/workbooks-sh/runtime:latest` (`cli/src/deploy/mod.rs:76`).

### Scaffold templates

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:558-587
- **SRC:** cli/src/deploy/mod.rs#TEMPLATE_LOCAL

- `init local` writes `TEMPLATE_LOCAL` (`#+DEPLOY_TARGET: local`, port 4000,
  `OPENROUTER_API_KEY` secret) — `cli/src/deploy/mod.rs:558`.
- `init cloud` / `init fly` writes `TEMPLATE_FLY` (`#+DEPLOY_TARGET: fly`,
  `#+DEPLOY_REGION: sjc`) — `cli/src/deploy/mod.rs:570`.

## The ONE OCI image

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:76
- **SRC:** runtime/host/deploy/image.ex#Image

There is ONE artifact: `ghcr.io/workbooks-sh/runtime:<tag>` — the BEAM runtime +
wasmtime + litestream + the release, with the in-sandbox compilers pulled in as a
separate layer (`COPY --from`). Every place runs the same image; a target is just
a routing config + endpoint, not a code fork.

| fact | value | src |
| --- | --- | --- |
| registry | `ghcr.io/workbooks-sh` | `runtime/host/deploy/image.ex:11` |
| image name | `runtime` | `runtime/host/deploy/image.ex:12` |
| canonical ref | `ghcr.io/workbooks-sh/runtime:latest` | `runtime/host/deploy/image.ex:21` |
| override env | `WB_IMAGE` | `runtime/host/deploy/image.ex:21` |
| Dockerfile | `ci/Dockerfile.runtime` | `runtime/host/deploy/image.ex:13` |
| compilers layer ref | `ghcr.io/workbooks-sh/compilers:latest` | `runtime/host/deploy/image.ex:24` |
| compilers env | `WB_COMPILERS_IMAGE` | `runtime/host/deploy/image.ex:24` |

## Local converge

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:431-491
- **SRC:** cli/src/deploy/mod.rs#apply_local

`#+DEPLOY_TARGET: local` runs the image in a container on this machine. The
engine is auto-detected in this preference order: `docker`, `podman`, `krunvm`
(`cli/src/deploy/mod.rs:359-361`); first one with a working `--version` wins.

| engine | mechanism | src |
| --- | --- | --- |
| `docker=/=podman` | `pull` then `run -d --name <app> -p <port>:<port>` with env + volumes | `cli/src/deploy/mod.rs:445` |
| `krunvm` | `create <image> --cpus 2 --mem 2048` then detached `start` | `cli/src/deploy/mod.rs:469` |

Mounted volumes + env on the container (`cli/src/deploy/mod.rs:436-454`):
`<app-dir>/disco → /disco` (discovery, `WB_DESKTOP_DIR`), =<app-dir>/data →
/data= (`WB_DATA`); env `WB_WEB=1`, `WB_DESKTOP=1`, `PORT=<port>`. After apply,
talk to it with `wb rt status` (`cli/src/deploy/mod.rs:464`).

> **krunvm limitation:** `krunvm` cannot deliver the kit's secrets env-file yet —
> `apply` bails if secrets are staged. Use docker/podman locally, or a cloud
> provider. (`cli/src/deploy/mod.rs:470-472`)

Re-applies are idempotent: docker/podman `rm -f` the prior container, krunvm
`delete=s the prior VM, before recreating (=cli/src/deploy/mod.rs:447,473`).

## Cloud converge (provider recipes)

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:373-399
- **SRC:** cli/deploy-kit/providers/_recipe.sh

Any `#+DEPLOY_TARGET:` other than `local` names a provider RECIPE at
`providers/<place>/bootstrap.sh`, which sources the neutral spine `_recipe.sh`
and fills five hooks. Adding a provider = dropping a `bootstrap.sh` — no
recompile (`cli/src/deploy/mod.rs:5-11`).

Recipe resolution order (`cli/src/deploy/mod.rs:279-298`):
1. `$WB_PROVIDERS_DIR`
2. `cli/deploy-kit/providers` (repo dev, walking up)
3. recipes EMBEDDED in the binary, materialized under the app dir (standalone).

### Recipe hooks (the provider contract)

- **MATURITY:** ships-today
- **EVIDENCE:** cli/deploy-kit/providers/_recipe.sh:5-8,51-75
- **SRC:** cli/deploy-kit/providers/_recipe.sh#wb_recipe_run

A `bootstrap.sh` sets `WB_RECIPE_PLACE`, fills these, and calls `wb_recipe_run`.

| hook | role | src |
| --- | --- | --- |
| `provider_ensure_app` | create the app/host | `cli/deploy-kit/providers/_recipe.sh:57` |
| `provider_set_secrets` | stage credentials | `cli/deploy-kit/providers/_recipe.sh:58` |
| `provider_attach_volume` | durable volume for the data dir | `cli/deploy-kit/providers/_recipe.sh:59` |
| `provider_deploy_image` | run the OCI image | `cli/deploy-kit/providers/_recipe.sh:60` |
| `provider_public_url` | the engine's URL | `cli/deploy-kit/providers/_recipe.sh:61` |
| `provider_down/status/logs` | lifecycle trio | `cli/deploy-kit/providers/_recipe.sh:69-71` |

Actions dispatched via `WB_RECIPE_ACTION` (`up` \vert `down` \vert `status` \vert
`logs` \vert `url` \vert `secrets`) — `cli/deploy-kit/providers/_recipe.sh:53`.
The engine env every provider forwards is assembled by `wb_base_env`
(`WB_WEB=1`, `PORT`, `WB_DATA`, `WB_REGISTRY`, plus tenancy / storage / db /
secret keys) — `cli/deploy-kit/providers/_recipe.sh:33-46`.

### Bundled provider: fly

- **MATURITY:** ships-today
- **EVIDENCE:** cli/deploy-kit/providers/fly/bootstrap.sh:32-92
- **SRC:** cli/deploy-kit/providers/fly/bootstrap.sh

Fly is the one bundled recipe (personal preference, not privileged —
`cli/deploy-kit/providers/fly/bootstrap.sh:2-3`). Requires `fly` / `flyctl` on
PATH (`:19-21`). Deploys either a prebuilt `WB_IMAGE` or, if `WB_FLY_CONFIG` /
`WB_FLY_DOCKERFILE` set, a remote build (`:52-82`). Public URL `https://<app>.fly.dev`
(`:88`). Lifecycle: `fly apps destroy --yes` / `fly status` / `fly logs`
(`:90-92`). Fly-specific env: `WB_FLY_APP`, `WB_FLY_CONFIG`, `WB_FLY_DOCKERFILE`,
`WB_INCLUDE_CLIP` (`:13-14`).

### Cloud bearer token

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:402-429
- **SRC:** cli/src/deploy/mod.rs#ensure_cloud_bearer

On the FIRST cloud `apply`, the kit generates a 256-bit random
`WB_PUBLIC_BEARER`, persists it in `secrets.env`, and delivers it to the engine —
the control plane rejects requests without it. It is generated ONCE and never
rotated (rotation would 401 all live clients). Set `WB_ENGINE_TOKEN=<token>` to
call the engine (`cli/src/deploy/mod.rs:406-422`).

## Environment variables (deploy-side)

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:324-346
- **SRC:** cli/src/deploy/mod.rs#recipe_action

| env | role | src |
| --- | --- | --- |
| `WB_IMAGE` | override the OCI image ref | `cli/src/deploy/mod.rs:127` |
| `WB_PROVIDERS_DIR` | explicit providers directory | `cli/src/deploy/mod.rs:280` |
| `WB_RECIPE_ACTION` | passed to recipe (`up/down/status/logs/url/secrets`) | `cli/src/deploy/mod.rs:327` |
| `WB_APP_NAME` / `WB_PORT` / `WB_REGION` | forwarded to recipe from config | `cli/src/deploy/mod.rs:330-332` |
| `WB_SECRET_KEYS` | space-separated names the recipe forwards | `cli/src/deploy/mod.rs:333` |
| `WB_PUBLIC_BEARER` | cloud control-plane bearer (auto-generated) | `cli/src/deploy/mod.rs:408` |
| `WB_ENGINE_TOKEN` | client token to call a locked engine | `cli/src/deploy/mod.rs:418` |
| `WB_FLY_APP/CONFIG/DOCKERFILE`, `WB_INCLUDE_CLIP`, `WB_EMBED` | passthrough overrides to recipes | `cli/src/deploy/mod.rs:342` |

## OQL kernel (WIT world)

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/kernel/wit/world.wit:6-22
- **SRC:** runtime/kernel/wit/world.wit#oql

The OQL kernel (`oql.wasm`) is a typed WebAssembly Component — pure in / pure
out, every export `string -> string`, no host imports, so it instantiates with no
WASI context and any fault traps inside Wasmtime
(`runtime/kernel/wit/world.wit:6-10`). Package `workbooks:oql`, world `oql`.

| export | signature | does | src |
| --- | --- | --- | --- |
| `parse-headlines` | `func(org: string) -> string` | Org structure → headline rows (JSON) | `runtime/kernel/wit/world.wit:13` |
| `lint` | `func(org: string) -> string` | Org → diagnostics (JSON) | `runtime/kernel/wit/world.wit:15` |
| `tangle-plan` | `func(org: string) -> string` | literate Workbook → WIT-world build plan (JSON) | `runtime/kernel/wit/world.wit:17` |
| `validate` | `func(org: string) -> string` | build plan → diagnostics | `runtime/kernel/wit/world.wit:19` |
| `check-upgrade` | `func(old: string, new: string) -> string` | diff deployed vs new world, refuse breaking | `runtime/kernel/wit/world.wit:21` |
| `render` | `func(org: string) -> string` | Org → rich HTML | `runtime/kernel/wit/world.wit:23` |

## Release layers (do not conflate)

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/deploy/image.ex:1-24
- **SRC:** runtime/host/deploy/image.ex#Image

Three distinct layers — Deploy Kit is only layer 3.

| layer | artifact | how published | src |
| --- | --- | --- | --- |
| 1 compilers package | `ghcr.io/workbooks-sh/compilers:{latest,sha}` | MANUAL, `publish_compilers/1`; CI cannot build it | `runtime/host/deploy/image.ex:97` |
| 2 runtime image | `ghcr.io/workbooks-sh/runtime:{latest,sha}` | CI (`runtime-image.yml`); `COPY --from` compilers | `runtime/host/deploy/image.ex:53` |
| 3 `wbx deploy` | runs the runtime image (user's registry/host) | USERS only — init/validate/apply/… | `cli/src/deploy/mod.rs:82` |

Layer-1/2 maintainer functions (NOT CLI verbs; not `wbx deploy`):
`Workbooks.Deploy.Image.build/1` (local single-arch, `image.ex:31`),
`publish/1` (multi-arch push, `image.ex:53`), `build_compilers/1` (`image.ex:80`),
`publish_compilers/1` (`image.ex:97`).

## Divergence: the Elixir backend model (NOT the shipped CLI)

- **MATURITY:** partial
- **EVIDENCE:** runtime/host/deploy/config.ex:1-13
- **SRC:** runtime/host/deploy/config.ex#Config
- **CAVEAT:** Richer deployment.org schema (`:PROPERTIES:` drawer, ENGINE_PLACE/TENANCY_MODE/STORAGE/DATABASE/AUTH, BYOD + multi-tenant validation) lives in the Elixir runtime backend and the deploy-kit example descriptors — NOT in the shipped Rust `wbx deploy`, which parses only flat `#+DEPLOY_*` keywords. The two schemas diverge; the SPEC notes the Elixir logic is migrating into `cli/src/deploy/` over time.
- **WALL:** none

`runtime/host/deploy/config.ex` and `backend.ex` implement a richer model parsed
from a `:PROPERTIES:` drawer (`config.ex:29-49`), used by the deploy-kit example
descriptors in `cli/deploy-kit/deployments/`:

| property (drawer) | allowed | src |
| --- | --- | --- |
| `:ENGINE_PLACE:` | `local` \vert `cloud` | `runtime/host/deploy/config.ex:15` |
| `:TENANCY_MODE:` | `single` \vert `multi` | `runtime/host/deploy/config.ex:16` |
| `:STORAGE:` | `local-fs` \vert `s3` | `runtime/host/deploy/config.ex:17` |
| `:DATABASE:` | `sqlite` \vert `postgres` | `runtime/host/deploy/config.ex:18` |
| `:AUTH:` | `trusted` \vert `betterauth` \vert `clerk` \vert `oidc` | `runtime/host/deploy/config.ex:19` |
| `:PROVIDER:` | cloud recipe name (default `fly`) | `runtime/host/deploy/config.ex:137` |

Coherence rules it enforces (`config.ex:56-83`): `multi` tenancy on `sqlite` is
rejected (one writer serializes tenants); `multi` needs real `AUTH`; `s3` needs
`STORAGE_BUCKET` + `STORAGE_ENDPOINT` + `WB_S3_KEY=/=WB_S3_SECRET` env; `postgres`
needs `WB_DATABASE_URL` env. Secrets stay in the deploy ENV, never the file
(`config.ex:6-9`). See examples `cli/deploy-kit/deployments/local.html` and
`cloud-saas.html`.

## See also

- How-to: `deploy/` guides (goal-titled tasks).
- Concepts: [the Dock & capabilities](../concepts/the-dock.md) · isolation tiers.
- Reference: [wbx CLI](./cli.md) · [Dock capabilities](./caps.md).
