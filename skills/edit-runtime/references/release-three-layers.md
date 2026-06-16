# Release / publishing — THREE separate layers. DO NOT CONFLATE.

This has tripped up sessions badly. Keep these distinct. Authoritative copy is
the repo `CLAUDE.md`; this is the working summary.

## 1. Compilers package — `ghcr.io/workbooks-sh/compilers:{latest,<sha>}`

- **What:** the in-sandbox WASM compiler toolchain (clang / mrustc+libstd / zig
  / go-yaegi / quickjs-ng) **plus the JS npm lane**
  (`compilers/js/bundle/bundlejob.js`, `compilers/js/shims/*`,
  `compilers/js/harness*.o`). Its OWN ghcr package.
- **Why manual:** gitignored artifacts from an hours-long provision chain.
  **CI cannot build it.**
- **How to publish:** from a **provisioned machine**, only when the compilers
  actually change. A bare maintainer function, NOT a CLI command:
  ```
  cd runtime && mix run --no-start -e "IO.inspect(Workbooks.Deploy.Image.publish_compilers())"
  ```
  Needs `docker login ghcr.io` + the `wb-multi` buildx builder (amd64+arm64).
- **Staging allowlist:** `runtime/scripts/stage-tools.sh` decides what enters
  the layer (explicit `take` lines → `compilers-dist/`). **Add a `take` for any
  new compiler asset** or it silently won't ship.
- This is **NOT** `work deploy`.

## 2. Runtime image — `ghcr.io/workbooks-sh/runtime:{latest,<sha>}`

- **What:** the BEAM runtime + wasmtime + litestream + the release. Contains
  `runtime/host/**` (the engine code).
- **How:** built by **CI/CD** — `.github/workflows/runtime-image.yml` on push to
  main. It `COPY --from`s the compilers package (layer 1).
- **So:** runtime code change → push to main, CI builds it (nothing manual).
  Compilers change → publish **layer 1 first** (manual, above), THEN CI rebuilds
  the runtime image on top.

## 3. `work deploy` (Deploy Kit) — USERS ONLY

- **What:** the tool for **consumers with our CLI** to deploy the runtime image
  for **their own use** — locally (krunvm) or cloud (Fly), to **their** registry
  via `WB_IMAGE`. Verbs: `init / validate / apply / update / verify / status /
  logs / down` (+ internal `build`/`publish` to a registry the user controls).
- **NOT** how *we* publish the compilers package or platform runtime image.
  **Never wire platform-release ops into `work deploy`.**

## Rule of thumb

*Compilers* ship as their own ghcr package, published **manually**. The
*runtime* ships via **CI**. **`work deploy` is the user's tool to run the
runtime** — not a platform-release mechanism.
