# The Workbook Runtime engine image (wb-11ck.30). One Linux container:
#   BEAM (the runtime) + wasmtime (run commands/components) + litestream
#   (off-box VFS durability) + the baked wasm artifacts (oql kernel, jq, grep).
# Build:  docker build -t workbooks-engine .
# Deploy: fly deploy   (the single credentialed step — needs Shane's Fly account)

# --- build: compile deps + the release --------------------------------------
FROM elixir:1.18-otp-27 AS build
ENV MIX_ENV=prod LANG=C.UTF-8
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
# wasmex is a VENDORED path dep — its source must exist before deps.compile.
COPY vendor ./vendor
RUN mix deps.get --only prod && mix deps.compile
COPY . .
# build/oql.wasm is embedded at compile time (@external_resource); it is COPY'd above.
RUN mix compile && mix release

# --- run: slim image with the release + the binaries it shells to ------------
FROM debian:bookworm-slim AS app
ENV LANG=C.UTF-8 WB_WEB=1 PORT=4000
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# wasmtime — runs the in-WASM commands (jq/grep) and components.
RUN curl -fsSL https://wasmtime.dev/install.sh | bash \
    && cp /root/.wasmtime/bin/wasmtime /usr/local/bin/wasmtime

# litestream — continuous VFS replication to R2/S3 (.19). Real binary, not stub.
ARG LITESTREAM_VERSION=0.5.11
RUN ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-${ARCH}.tar.gz" \
      | tar -xz -C /usr/local/bin litestream

COPY --from=build /app/_build/prod/rel/workbooks ./
# Runtime-read wasm commands live under build/commands at the app CWD.
COPY --from=build /app/build ./build
# In-sandbox compile toolchain — the LEAN ~600M slice from scripts/stage-tools.sh (NOT the ~6.6G
# provisioned scratch tree, which .dockerignore excludes). default_root() resolves "compilers" at
# the app CWD, so the deployed runtime compiles Rust/C/Zig/Go/JS identically to dev. Run
# `bash scripts/stage-tools.sh` before `docker build`. (deploy/Dockerfile.runtime, the deploy-kit's
# repo-root-context variant that `wb deploy build` uses, carries the same COPY.)
COPY compilers-dist ./compilers

EXPOSE 4000
CMD ["bin/workbooks", "start"]
