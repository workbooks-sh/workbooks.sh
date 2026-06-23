# The nexus runtime OCI image — the ONE image `Nexus.Deploy.Machine` boots in a krunvm/libkrun
# microVM (`Nexus.Deploy.local/2`) locally, and on a cloud machine. Entrypoint = the mix release at
# /app/bin/nexus; the Machine runs `/app/bin/nexus eval <boot-expr>` (WORKDIR /app, /data volume,
# port 4000). Build the release, then a slim Debian runtime with wasmtime + the in-sandbox compilers.
#
# Build CONTEXT = the REPO ROOT. nexus is now self-contained: wasmex (vendor/wasmex), the compilers
# (compilers-dist), and the toolchain reactor (priv/work-toolchain.wasm) all live UNDER nexus/.
#
#   nexus/scripts/stage-reactor.sh                  # build + stage priv/work-toolchain.wasm
#   nexus/scripts/stage-tools.sh                    # stage the lean ~600M compilers-dist
#   docker build -f nexus/Dockerfile -t nexus:local \
#     --build-arg COMPILERS_DIR=nexus/compilers-dist .
#
# The compilers (a ~7.2G gitignored toolchain) are NOT in git; the lean ~600M slice must be PRESENT in
# the build context under ${COMPILERS_DIR} (staged by nexus/scripts/stage-tools.sh). See the
# nexus-image workflow + docs/OCI-IMAGE.md.

# The compilers layer (ci/Dockerfile.compilers), referenced as a named stage. Docker forbids a
# variable in `COPY --from`, but a GLOBAL ARG in `FROM` is allowed — so we alias it to `compilers`
# and COPY from that stage below. `compilers:local` for a local build; the ghcr ref for CI/publish
# (the 7.2G wasm toolchain is published ONCE from a provisioned machine, never rebuilt in CI).
ARG COMPILERS_REF=compilers:local
FROM ${COMPILERS_REF} AS compilers

# --- build: the Elixir release ----------------------------------------------
FROM elixir:1.19-otp-27 AS build
ENV MIX_ENV=prod LANG=C.UTF-8
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git curl \
    && rm -rf /var/lib/apt/lists/*
# Rust toolchain — wasmex's NIF (rustler) is compiled from source in the release build.
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
RUN mix local.hex --force && mix local.rebar --force

# wasmex is a VENDORED path dep ({:wasmex, path: "vendor/wasmex"}) — its source must exist before
# deps.compile. Copy the manifests + the vendored wasmex first to keep the dep layer cached.
COPY nexus/mix.exs nexus/mix.lock ./
COPY nexus/vendor/wasmex /app/vendor/wasmex
# BuildKit cache mounts: `deps/` + `_build/` PERSIST across builds (and from this step into the compile
# step, via the shared ids). A source-only change busts the `COPY nexus/` layer below, but `mix compile`
# then reuses the cached `_build` and recompiles ONLY changed modules — minutes → seconds. The mounts are
# ephemeral (not committed to a layer), so the release is copied OUT to /app/rel for the final COPY.
RUN --mount=type=cache,target=/app/deps,id=nexus-deps \
    --mount=type=cache,target=/app/_build,id=nexus-build \
    mix deps.get --only prod && mix deps.compile

COPY nexus/ .
RUN --mount=type=cache,target=/app/deps,id=nexus-deps \
    --mount=type=cache,target=/app/_build,id=nexus-build \
    mix compile && mix release nexus --overwrite && rm -rf /app/rel && cp -a _build/prod/rel/nexus /app/rel

# --- run --------------------------------------------------------------------
FROM debian:bookworm-slim AS app
LABEL org.opencontainers.image.source="https://github.com/workbooks-sh/workbooks.sh"
LABEL org.opencontainers.image.description="nexus runtime — the fresh BEAM engine (literate .work → wasm), wasmtime + in-sandbox compilers"
ENV LANG=C.UTF-8 PORT=4000 WB_DATA=/data
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 ca-certificates curl xz-utils \
      git jq sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# Pinned: install.sh's "latest" lookup hits the GitHub API unauthenticated and rate-limits on shared
# CI runners. Same pin as the runtime image. The compile lane (Nexus.Compilers.Shared.wasmtime/1)
# shells `wasmtime run`, so the binary must be on PATH.
ARG WASMTIME_VERSION=v45.0.1
RUN curl -fsSL https://wasmtime.dev/install.sh | bash -s -- --version ${WASMTIME_VERSION} \
    && cp /root/.wasmtime/bin/wasmtime /usr/local/bin/wasmtime

# Litestream — durability: streams the tenant SQLite WAL to the object store (R2/Tigris, egress-free)
# + restores on boot. Generic mechanism (Nexus.Litestream); activates only when S3 secrets are
# injected (see entrypoint), so a no-replica deployment runs SQLite-on-volume unchanged.
ARG LITESTREAM_VERSION=v0.3.13
RUN curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-$(dpkg --print-architecture).tar.gz" \
    | tar -xz -C /usr/local/bin litestream && litestream version

# The mix release → /app. The Machine boots /app/bin/nexus (WORKDIR /app). The release is copied out of
# the (ephemeral) _build cache mount to /app/rel in the build stage, so we COPY from there.
COPY --from=build /app/rel ./
# Durability wrapper: restore-from-replica-if-empty → `litestream replicate -exec bin/nexus start`.
COPY nexus/scripts/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# The in-sandbox compilers, from the standalone compilers LAYER (the `compilers` stage above) so CI
# never rebuilds the hours-long provision chain. Nexus.Compilers.Shared.default_root/0 resolves
# "compilers" at the app CWD, so cloud AND local-container deployments compile Rust/C/Zig/Go/JS
# identically to dev. (The toolchain REACTOR — priv/work-toolchain.wasm, staged by
# nexus/scripts/stage-reactor.sh — and the wasi adapter — build/tools — ship inside the release.)
COPY --from=compilers /compilers ./compilers

EXPOSE 4000
# The entrypoint wraps `bin/nexus start` in litestream replication (restore-on-boot → replicate
# -exec). The Machine can still override with `eval <boot-expr>` for one-shot pipeline boots.
CMD ["/app/entrypoint.sh"]
