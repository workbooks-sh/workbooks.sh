
# Deploy the runtime to the cloud

> Run the Workbooks runtime on a cloud provider under your own account.

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:169
- **OWNER:** cli

Cloud deploys are **recipe-driven**. A provider is a `providers/<place>/bootstrap.sh`
filling the neutral spine's hooks — adding a provider means dropping a bootstrap
script, no recompile. Fly is the recipe we bundle (a default, not a privilege);
it runs under **your own** account.

```bash
wbx deploy init cloud   # scaffold deployment.org for the cloud preset
wbx deploy secrets set KEY=VALUE
wbx deploy apply        # converge via the provider recipe
```

## Where recipes resolve from

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:13
- **SRC:** cli/src/deploy/mod.rs#run

`$WB_PROVIDERS_DIR` → `./cli/deploy-kit/providers` (repo dev) → recipes embedded in
the `wbx` binary, materialized under the app dir (standalone installs).

## Secrets

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:17

Secrets are declared by NAME in `deployment.org` (`#+DEPLOY_SECRETS:`), set via
`wbx deploy secrets`, and delivered per provider — staged through the recipe's
`provider_set_secrets` hook in the cloud. Values never enter `deployment.org` or
images.

The full verb/flag/provider matrix is in [Reference → Deploy & kernel](../reference/deploy.md).
