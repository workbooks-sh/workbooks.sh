
# Deploy a runtime to the internet

> Bring a runtime up — locally in a container or on a cloud provider — with wbx deploy, the bootstrap verb.

The goal: stand a runtime up somewhere it can serve. `wbx deploy` is the **bootstrap**
verb — special because it runs with no runtime up; it's what brings the runtime up.
It reads a `deployment.org` file and converges to that declared state.

This is the USER tool for running the runtime image for your own use — local
(container) or cloud (a provider recipe). It is NOT how the platform itself
publishes the compilers package or the runtime image; do not conflate those.

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:1
- **SRC:** cli/src/deploy/mod.rs#DeployVerb

## Steps

1. **Scaffold the config.** `wbx deploy init [local|cloud]` writes a `deployment.org`.
   On a TTY, omit the preset to pick interactively. Edit it, then apply.
- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:33

2. **Stage any secrets.** Secrets are declared by NAME in `deployment.org`
   (`#+DEPLOY_SECRETS: KEY …`); values are managed out-of-band and never enter the
   file or the image. Use `wbx deploy secrets set KEY=VALUE …` (or `--from-env <file>`).
- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:60
- **CAVEAT:** values stored 0600 under the app dir; delivered per provider (env-file locally, recipe hook in the cloud).

3. **Validate.** `wbx deploy validate` runs a coherence check on `deployment.org`,
   including that every declared secret is set.
- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:38

4. **Apply.** `wbx deploy apply` converges to the declared state — a local container
   or a provider recipe. The shorthand `wbx deploy local` scaffolds local config if
   absent, then applies.
- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:41

5. **Operate.** `wbx deploy status` inspects the live deployment, `wbx deploy logs`
   tails its logs, `wbx deploy down` tears it down. `wbx deploy doctor` reports which
   engines, recipes, and declared secrets are present vs missing.
- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:43

## Where it can run

- **local** — the container-engine seam: `docker` | `podman` | `krunvm`, built in.
- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:7

- **a cloud provider** — anything else is a RECIPE: a `providers/<place>/bootstrap.sh`
  filling the neutral spine's hooks. Adding a provider = dropping a bootstrap.sh,
  no recompile. `fly` is the recipe bundled today.
- **MATURITY:** partial
- **EVIDENCE:** cli/deploy-kit/providers/fly
- **CAVEAT:** only the fly recipe ships in-tree; other clouds require authoring a bootstrap.sh against the spine.

## Three release layers — do not conflate

This is the **user's** tool to run the runtime. It is distinct from how the platform
ships code:

- The compilers package — its own ghcr package, published manually.
- The runtime image — built by CI on push to main.
- `wbx deploy` — consumers running the runtime image for their own use. ←  **this page.**

- **MATURITY:** ships-today
- **EVIDENCE:** CLAUDE.md

- Then connect the CLI to it: [Connect the CLI to a runtime engine](../run/connect-an-engine.md)
- Publish a workbook to a static surface instead: [Publish](../workbooks/publish.md)
