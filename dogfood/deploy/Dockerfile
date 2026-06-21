# Slim dogfood-runtime: current nexus release (serve_static + auth + SSR) serving dogfood/.
# No wasm compilers — the dogfood surfaces compile no wasm.
FROM elixir:1.19-otp-27 AS build
ENV MIX_ENV=prod LANG=C.UTF-8
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git curl && rm -rf /var/lib/apt/lists/*
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
RUN mix local.hex --force && mix local.rebar --force
COPY nexus/mix.exs nexus/mix.lock ./
COPY nexus/vendor/wasmex /app/vendor/wasmex
RUN mix deps.get --only prod && mix deps.compile
COPY nexus/ .
RUN mix compile && mix release nexus

FROM debian:bookworm-slim AS app
ENV LANG=C.UTF-8 PORT=4000 WB_DATA=/srv/dogfood WB_NEXUS=dogfood
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates sqlite3 curl && rm -rf /var/lib/apt/lists/*
# Litestream — streams the tenant SQLite WAL to R2 (egress-free) + restores on boot. Generic
# durability mechanism; activates only when WB_S3_* secrets are injected (see entrypoint).
ARG LITESTREAM_VERSION=v0.3.13
RUN curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin litestream && litestream version
COPY --from=build /app/_build/prod/rel/nexus ./
# The deploy config lives in the deploy-root index.work (deploy-as-index-tree) — Nexus.Config reads
# $WB_DATA/index.work (= /srv/dogfood/index.work), which rides in with the tree below. No sidecar.
COPY dogfood /srv/dogfood
COPY nexus/scripts/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
EXPOSE 4000
CMD ["/app/entrypoint.sh"]
