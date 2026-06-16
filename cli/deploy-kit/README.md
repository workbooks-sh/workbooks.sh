# deploy-kit — assets behind `work deploy` (for users/devs of the kit)

The deploy kit itself is compiled into the `work` binary (`cli/src/deploy/`). This
folder holds its on-disk assets:

- `deployments/` — example `deployment.org` declarations (`local.org`,
  `cloud-saas.org`). `work deploy init [local|cloud]` scaffolds equivalents.
- `providers/` — cloud-provider recipes: `_recipe.sh` is the neutral spine; each
  `<place>/bootstrap.sh` (e.g. `fly/`) fills its hooks. Read by the Elixir
  deploy backend (`runtime/host/deploy/backend.ex`) and our `ci/deploy.sh`.
- `storage.env.example` — the "one screen" of storage/identity config a
  deployment needs; set as platform secrets, never baked into images.

OUR platform-release infra (runtime/compilers images, the brandnana prod app)
is NOT here — see `ci/`.
