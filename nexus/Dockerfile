# The nexus runtime OCI image — the ONE image `Nexus.Deploy.Machine` boots in a krunvm/libkrun
# microVM (`Nexus.Deploy.local/2`) locally, and on a cloud machine. Entrypoint = the mix release at
# /app/bin/nexus; the Machine runs `/app/bin/nexus eval <boot-expr>` (WORKDIR /app, /data volume,
# port 4000). Mirrors runtime/ci/Dockerfile.runtime: build the release, then a slim Debian runtime
# with wasmtime + the in-sandbox compilers.
#
# Build CONTEXT = the REPO ROOT (not nexus/) — nexus depends on ../runtime/vendor/wasmex (a vendored
# path dep) and on runtime/compilers/, both of which sit outside nexus/. Build via deploy/build.sh,
# which sets the context and stages the compilers.
#
#   docker build -f nexus/Dockerfile -t nexus:local \
#     --build-arg COMPILERS_DIR=runtime/compilers-dist .
#
# The compilers (a ~7.1G gitignored toolchain) are NOT in git; they must be PRESENT in the build
# context under ${COMPILERS_DIR}. Like the runtime, the lean ~600M slice is staged first via
# runtime/scripts/stage-tools.sh → runtime/compilers-dist. See deploy/build.sh and docs/OCI-IMAGE.md.

# --- build: the Elixir release ----------------------------------------------
FROM elixir:1.18-otp-27 AS build
ENV MIX_ENV=prod LANG=C.UTF-8
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git curl \
    && rm -rf /var/lib/apt/lists/*
# Rust toolchain — wasmex's NIF (rustler) is compiled from source in the release build.
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
RUN mix local.hex --force && mix local.rebar --force

# wasmex is a VENDORED path dep ({:wasmex, path: "../runtime/vendor/wasmex"}) — its source must exist
# before deps.compile. Copy the manifests + the vendored wasmex first to keep the dep layer cached.
COPY nexus/mix.exs nexus/mix.lock ./
COPY runtime/vendor/wasmex /runtime/vendor/wasmex
RUN mix deps.get --only prod && mix deps.compile

COPY nexus/ .
RUN mix compile && mix release nexus

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

# The mix release → /app. The Machine boots /app/bin/nexus (WORKDIR /app).
COPY --from=build /app/_build/prod/rel/nexus ./

# The in-sandbox compilers. Nexus.Compilers.Shared.default_root/0 resolves "compilers" at the app
# CWD first, so landing them at /app/compilers makes cloud AND local-container builds compile
# Rust/C/Zig identically to dev. COPY'd from the build context (NOT a separate stage) — the compilers
# are gitignored artifacts staged into the context by deploy/build.sh; see docs/OCI-IMAGE.md for the
# layer-as-its-own-package strategy the runtime uses (and why we COPY here for now).
ARG COMPILERS_DIR=runtime/compilers-dist
COPY ${COMPILERS_DIR} ./compilers

EXPOSE 4000
# The Machine overrides this with `eval <boot-expr>`; `start` is the conventional default.
CMD ["bin/nexus", "start"]
