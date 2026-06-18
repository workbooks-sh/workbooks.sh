# The nexus OCI image

The **one image** `Nexus.Deploy.Machine` boots in a krunvm/libkrun microVM locally
(`Nexus.Deploy.local/2`) and on a cloud machine. It is the layer *outside* the engine; nexus's own
wasmtime sandbox (where untrusted `.work` unit code runs) is a separate inner boundary.

This mirrors the runtime's image recipe (`runtime/host/deploy/image.ex` + `runtime/ci/Dockerfile.*`),
adapted for the `nexus` mix release.

## What's in it

A two-stage Debian image (`nexus/Dockerfile`):

| Layer | Contents | Why |
|-------|----------|-----|
| `build` (elixir:1.18-otp-27) | `mix release nexus` with a Rust toolchain | compiles wasmex's rustler NIF + the BEAM release |
| `app` (debian:bookworm-slim) | the release at `/app`, `wasmtime`, the in-sandbox compilers at `/app/compilers` | the runtime the Machine boots |

- **Entrypoint:** the mix release `/app/bin/nexus`. `Nexus.Deploy.Machine.start_argv/1` runs
  `/app/bin/nexus eval "<boot-expr>"` — it does **not** use `bin/nexus start` (the release console
  needs a TTY the krunvm guest lacks). The boot expr is
  `Application.ensure_all_started(:nexus) … Process.sleep(:infinity)`.
- **WORKDIR `/app`**, **`/data` volume** (`WB_DATA=/data`), **port `4000`** — the contract
  `Machine.create/2` maps (`--workdir /app`, `--volume <host>:/data`, `--port H:4000`).
- **`wasmtime`** on PATH — `Nexus.Compilers.Shared.wasmtime/1` shells `wasmtime run` as the sandbox
  executor. Pinned `v45.0.1` (same as the runtime image; "latest" rate-limits on CI).
- **the in-sandbox compilers** at `/app/compilers` — `Nexus.Compilers.Shared.default_root/0`
  resolves `"compilers"` at the app CWD first, so Rust/C/Zig compile identically to dev.

## The release (`mix.exs`)

- `releases: [nexus: [...]]` → `mix release nexus` emits `_build/prod/rel/nexus/bin/nexus`,
  ERTS + BEAM bundled (the runtime image needs no Elixir installed).
- `application/0` sets `mod: {Nexus.Application, []}` and lists `:wasmex` in `extra_applications`, so
  the boot expr's `Application.ensure_all_started(:nexus)` returns `{:ok, _}` (verified: it starts
  `:wasmex`, `:rustler_precompiled`, `:nexus`, …) and the empty supervision tree keeps the node
  alive under `Process.sleep(:infinity)`.
- `Nexus.Application` (`lib/application.ex`) is intentionally an **empty supervision tree** — nexus is
  today a library of pure pipelines with no long-lived processes. Add children here (a control-plane
  HTTP listener, a store supervisor) as the runtime grows a server surface.

## Building it

The build **context is the repo root** (nexus depends on `../runtime/vendor/wasmex` and on the
compilers, both outside `nexus/`). Use the script:

```bash
nexus/deploy/build.sh [IMAGE_TAG]          # default tag: nexus:local
# env: COMPILERS_DIR (default runtime/compilers-dist), SKIP_STAGE=1, PLATFORM, INTO_KRUNVM=1
```

Or directly:

```bash
docker build -f nexus/Dockerfile -t nexus:local \
  --build-arg COMPILERS_DIR=runtime/compilers-dist .
```

## The compilers-staging requirement (READ THIS)

The in-sandbox compilers are a **~7.1G gitignored toolchain** (mrustc/clang/libstd/zig/yaegi/qjs…)
built by an hours-long provision chain. They are **NOT in git** and **CI cannot reproduce them
per-build**. The image bundles the **lean ~600M slice**, staged exactly as the runtime does:

1. `runtime/scripts/stage-tools.sh` copies the lean slice → `runtime/compilers-dist`
   (the `take`-line allowlist decides what ships; add a `take` for any new compiler asset).
2. The Dockerfile `COPY ${COMPILERS_DIR} ./compilers` lands it at `/app/compilers`.

`build.sh` runs step 1 for you (unless `SKIP_STAGE=1`). On a machine **without** the provisioned
toolchain, staging fails — that is expected; provision the compilers first.

**Recommended next step (mirror the runtime):** publish the compilers as their **own ghcr layer**
(`Dockerfile.compilers` → `ghcr.io/workbooks-sh/compilers`, pushed manually when they change) and
switch the nexus Dockerfile to `COPY --from=<compilers-layer> /compilers ./compilers`. That keeps
the nexus image build fast and CI-buildable. For now we `COPY` from the staged context dir so the
recipe is self-contained and doesn't presuppose a published layer.

## How `Nexus.Deploy.local/2` consumes it

```elixir
Nexus.Deploy.local("nexus:local", host_port: 4000, env: %{"WB_KEY" => "…"})
```

1. `Machine.preflight/0` — checks `krunvm` is installed + the case-sensitive APFS `krunvm` volume.
2. `Machine.create/2` — `krunvm create nexus:local --workdir /app --port H:4000 --volume <data>:/data`.
3. `Machine.spawn_direct/1` — runs `start_argv/1`:
   `krunvm start nexus-runtime --env WB_DATA=/data … -- /app/bin/nexus eval "<boot-expr>"`,
   detached, in the user's GUI session (libkrun needs Aqua; a LaunchAgent fails EX_CONFIG).
4. Returns `{:ok, %{url: "http://127.0.0.1:4000", host_port, data_dir, vm}}`.

`Nexus.Deploy.down/0` kills the spawned pid and `krunvm delete`s the VM.

## What's verified vs. not

**Verified (this machine, macOS):**
- `mix compile` clean; `mix deps.get` resolves.
- `MIX_ENV=prod mix release nexus` produces `_build/prod/rel/nexus/bin/nexus`.
- `bin/nexus eval 'Application.ensure_all_started(:nexus)'` → `{:ok, [… :wasmex, :nexus]}` —
  i.e. the exact boot path `Machine.start_argv/1` uses works.

**Not verified (no toolchain in this worktree, expected):**
- The full `docker build` — requires the ~7.1G compilers staged into the context and a Linux
  wasmex NIF rebuild (slow; the dev `.so` is macOS). The Dockerfile is a documented recipe.
- A live `krunvm` boot of the built image.
