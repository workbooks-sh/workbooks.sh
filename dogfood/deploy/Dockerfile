# Slim dogfood-runtime: current nexus release (serve_static + auth + SSR) serving dogfood/.
# No wasm compilers — the dogfood surfaces compile no wasm.
FROM elixir:1.18-otp-27 AS build
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
RUN apt-get update && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates sqlite3 && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/_build/prod/rel/nexus ./
COPY dogfood /srv/dogfood
COPY dogfood/nexus/deployment.work /app/deployment.work
EXPOSE 4000
CMD ["bin/nexus", "start"]
