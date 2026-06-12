# Deploy commands — `wbx deploy`

Stand up the ONE runtime OCI image, local or cloud. One image, two places. Every
verb is **non-interactive, idempotent, and exits non-zero on failure**; add
`--json` to any verb for a machine-readable result map. See `../deploykit.md` for
the model and `../env.md` for the engine env contract.

The declarative flow is reproducible: scaffold → edit → validate → apply.
Lifecycle verbs default to `./deployment.org`; pass a path to use another file.
With no file they operate on the local daemon.

TOC: init · validate · apply · local · doctor · status · verify · logs · down ·
build · publish · the deployment.org spec

## `wbx deploy init [local|cloud]`

- **Need:** start a reproducible deployment description.
- **Action:** scaffolds `./deployment.org` from the `local` (default) or `cloud`
  preset. `--force` overwrites.
- **Success:** `wrote deployment.org (local) — edit it, then validate → apply`.
- **Failure:** `<file> already exists …`; `unknown preset '<x>' — try: local | cloud`.

## `wbx deploy validate [file]`

- **Need:** catch config errors before deploying (the write-then-submit gate).
- **Action:** parses + coherence-checks the file. No deploy.
- **Success:** `valid — <summary>`. **Failure:** `invalid deployment:` + a
  bulleted issue list; `no deployment.org — run wbx deploy init`.

## `wbx deploy apply [file]`

- **Need:** converge the environment to the config.
- **Action:** validates, then dispatches on `ENGINE_PLACE`: `local` → a krunvm
  microVM (cloud-identical isolation); `cloud` → the configured `PROVIDER` recipe
  under `cli/deploy-kit/providers/<provider>`. `TENANCY_MODE`, `STORAGE`,
  `DATABASE`, and `PROFILE` flow to the engine as env.
- **Success:** the local-up / cloud-deploy message with the URL.
- **Failure:** invalid config; `ENGINE_PLACE must be local|cloud`; `cloud
  PROVIDER=<p> has no recipe …`.

## `wbx deploy local`

- **Need:** run the runtime locally right now, zero config (like `docker run`).
- **Action:** doctor → create the microVM → direct-spawn it in the caller's GUI
  session (not launchd — libkrun fails under a background LaunchAgent) → await the
  discovery file.
- **Success:** `local runtime up — http://… (survives app quit; wbx deploy down to
  stop)`. If discovery doesn't land in time: `VM spawned … but no discovery yet`
  (still `:ok`; the image may be booting).

## `wbx deploy doctor`

- **Need:** check + self-heal local prerequisites. The first thing to run.
- **Action:** preflight krunvm + the case-sensitive APFS volume; creates the
  volume if missing.
- **Success:** `prereqs OK` (or `created the case-sensitive APFS volume…`).

## `wbx deploy status [file]`

- **Need:** is it up? `local` by default; a cloud `deployment.org` reports the
  cloud deployment's state.
- **Success (local):** `local runtime: microVM present; runtime up — http://… (pid …)`.

## `wbx deploy verify [file]`

- **Need:** prove the LIVE runtime answers.
- **Action:** local — read discovery, `GET /health` with the token. Cloud — ask
  the provider for the URL, then `GET <url>/health`.
- **Success:** `runtime healthy — …/health → 200`.
- **Failure:** `no discovery file — is the daemon up? wbx deploy local`;
  `runtime reachable but unhealthy (HTTP …)`; `could not verify cloud runtime …`.

## `wbx deploy logs [file]`

- **Need:** find where logs are.
- **Action (local):** prints a `tail -f` line pointing at the daemon's
  stdout/stderr logs under `~/Library/Application Support/sh.workbooks/logs`.

## `wbx deploy down [file]`

- **Need:** tear it down.
- **Action (local):** stops the runtime; **data + APFS volume are preserved**.
- **Success:** `local runtime down (data + APFS volume preserved)`.

## `wbx deploy build` / `wbx deploy publish`

- **Need:** build / push the one runtime image (the image artifact, not a user
  deployment).
- **Action:** `build` builds the image (and loads it into krunvm); `publish`
  pushes it to the registry.
- **Failure:** `command not found (is docker/buildx installed?)`.
- **Platform note:** publishing the *runtime image* is normally CI's job, and the
  separate *compilers* package is published manually outside this CLI — do not
  conflate `wbx deploy` with platform-release ops.

## The deployment.org spec

A `:deployment:`-tagged node whose `:PROPERTIES:` drawer carries:

- `ENGINE_PLACE` `local` | `cloud`
- `TENANCY_MODE` `single` | `multi`
- `STORAGE` `local-fs` | `s3` (+ `STORAGE_ENDPOINT`/`_BUCKET`/`_REGION` for s3)
- `DATABASE` `sqlite` | `postgres`
- `AUTH` `trusted` | `clerk` | … (+ `ISSUER` for an OIDC issuer)
- cloud only: `PROVIDER` (default `fly`), `APP`, `REGION`
- optional `PROFILE` (path to an agent profile)

**Secrets never go in the file** — S3 keys, DB DSN come from ENV (`WB_S3_KEY`,
`WB_S3_SECRET`, `WB_DATABASE_URL`). See `../env.md`.
