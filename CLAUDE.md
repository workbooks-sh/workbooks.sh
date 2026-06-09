# Workbooks — repo guidance

## Release / publishing — THREE separate layers. DO NOT CONFLATE THEM.

This tripped up a session badly once. Keep these distinct:

### 1. Compilers package — `ghcr.io/workbooks-sh/compilers:{latest,<sha>}`
- **What:** the in-sandbox wasm compiler toolchain (clang / mrustc+libstd / zig / go-yaegi / quickjs-ng) **plus the JS npm lane** (`compilers/js/bundle/bundlejob.js`, `compilers/js/shims/*`, `compilers/js/harness.o`, `compilers/js/harness_dock.o`). It is its **own ghcr package**.
- **Why manual:** these are gitignored artifacts from an hours-long provision chain. **CI cannot build it.**
- **How to publish:** from a **provisioned machine**, occasionally — only when the compilers actually change. It is a bare maintainer function, **not a CLI command**:
  ```
  cd runtime && mix run --no-start -e "IO.inspect(Workbooks.Deploy.Image.publish_compilers())"
  ```
  Needs `docker login ghcr.io` + the `wb-multi` buildx builder (multi-arch amd64+arm64).
- **Staging allowlist:** `runtime/scripts/stage-tools.sh` decides what goes in the layer (explicit `take` lines → `compilers-dist/`). **If you add a new compiler asset, add a `take` for it here** or it silently won't ship. (This is exactly how the whole npm lane was missing once.)
- This is **NOT** `wb deploy`.

### 2. Runtime image — `ghcr.io/workbooks-sh/<runtime>:{latest,<sha>}`
- **What:** the BEAM runtime + wasmtime + litestream + the release. Contains `runtime/host/**` (the engine code).
- **How:** built by **CI/CD** — `.github/workflows/runtime-image.yml` on push to main. It `COPY --from`s the **compilers package (layer 1)** for the in-sandbox toolchain.
- **So:**
  - Ship a **runtime code** change → push to main; CI builds the image. Nothing manual.
  - Ship a **compilers** change → publish **layer 1 first** (manual, above), THEN CI rebuilds the runtime image on top of the new compilers package.

### 3. `wb deploy` (Deploy Kit) — USERS ONLY
- **What:** the tool for **consumers who have our CLI** to deploy the runtime image for **their own use** — locally (krunvm) or on a cloud target (Fly), to **their** registry via `WB_IMAGE`. Verbs: `init / validate / apply / update / verify / status / logs / down` (+ internal `build`/`publish` that push the runtime image to a registry the user controls).
- **It is NOT** how *we* publish the compilers package or the platform runtime image. **Never wire platform-release ops (like the compilers publish) into `wb deploy`.**

**Rule of thumb:** the *compilers* ("the building thing" that builds workbook files) ship as their own ghcr package, published **manually**. The *runtime* ships via **CI**. **`wb deploy` is the user's tool to run the runtime** — not a platform-release mechanism.
