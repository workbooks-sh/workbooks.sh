# ci/ — OUR release infrastructure (not for users)

Platform-release artifacts for workbooks.sh itself. Users never touch this; the
user-facing deploy tooling is `wb deploy` (the CLI) + `cli/deploy-kit/`.

| File | What | Built/run by |
|---|---|---|
| `Dockerfile.runtime` | the generic runtime image → `ghcr.io/workbooks-sh/runtime` | CI: `.github/workflows/runtime-image.yml` on push to main |
| `Dockerfile.compilers` | the in-sandbox compilers layer → `ghcr.io/workbooks-sh/compilers` | manual, from a provisioned machine (`Workbooks.Deploy.Image.publish_compilers/0`) |
| `Dockerfile` + `fly.toml` + `deploy.sh` | OUR production engine (brandnana) on Fly | manual: `bash ci/deploy.sh` |

Rule of thumb (CLAUDE.md "three layers"): compilers ship manually, the runtime
image ships via CI, and `wb deploy` is the **user's** tool — never wire platform
release ops into it.
