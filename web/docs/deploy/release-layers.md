
# The three release layers

> Compilers package, runtime image, and wb deploy — three separate layers. Do not conflate them.

- **MATURITY:** ships-today
- **EVIDENCE:** CLAUDE.md:Release / publishing
- **OWNER:** cli

Three publishing layers exist and must stay distinct. Conflating them breaks
releases.

## 1. Compilers package

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/scripts/stage-tools.sh:1

`ghcr.io/workbooks-sh/compilers:{latest,<sha>}` — the in-sandbox WASM compiler
toolchain (clang / mrustc+libstd / zig / go-yaegi / quickjs-ng) plus the JS npm
lane. Its **own** ghcr package. Published **manually** from a provisioned machine —
CI cannot build it. The staging allowlist (`runtime/scripts/stage-tools.sh`)
decides what ships; add a `take` line for any new compiler asset.

## 2. Runtime image

- **MATURITY:** ships-today
- **EVIDENCE:** .github/workflows/runtime-image.yml:1

`ghcr.io/workbooks-sh/runtime:{latest,<sha>}` — the BEAM runtime + wasmtime +
litestream + the release, containing `runtime/host/**`. Built by **CI** on push to
main; it =COPY --from='s the compilers package (layer 1). Runtime code change →
push → CI rebuilds. Compilers change → publish layer 1 first, then CI rebuilds the
runtime on top.

## 3. wb deploy (Deploy Kit) — users only

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:1

The tool for **consumers with the CLI** to deploy the runtime image for their own
use — locally (krunvm/podman/docker) or cloud (Fly), to **their** registry. Never
wire platform-release ops into `wb deploy`.

**Rule of thumb:** compilers ship as their own ghcr package, published manually; the
runtime ships via CI; `wb deploy` is the user's tool to run the runtime.

See [Deploy locally](local.md) and [Deploy to the cloud](cloud.md) for the user path.
