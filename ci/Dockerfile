# The Workbooks production engine — the :workbooks runtime + the brandnana
# brand-book toolkit, built entirely from THIS repo (no old-monorepo staging).
# Build CONTEXT = the repo root. Deploy: bash deploy/deploy.sh
#
#   runtime/            -> the BEAM engine (mix release)
#   projects/brandnana  -> the brandnana CLI (bun --compile) + profile + boards
#
# No `wb` CLI baked in: the agents query the substrate via brandnana, not a CLI.

# --- brandnana CLI: self-contained bun binary ---------------------------------
FROM oven/bun:1 AS brandnana-cli
WORKDIR /src/brandnana
COPY projects/brandnana/package.json projects/brandnana/bun.lock ./
COPY projects/brandnana/packages ./packages
COPY projects/brandnana/apps/cli ./apps/cli
RUN --mount=type=cache,target=/root/.bun/install/cache,sharing=locked \
    bun install --ignore-scripts && bash apps/cli/scripts/build-binary.sh linux-x64

# --- runtime: the Elixir release ---------------------------------------------
FROM elixir:1.18-otp-27 AS build
ENV MIX_ENV=prod LANG=C.UTF-8
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential git curl \
    && rm -rf /var/lib/apt/lists/*
# Rust toolchain for any rustler NIF.
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
RUN mix local.hex --force && mix local.rebar --force
# Opt-in (--build-arg INCLUDE_CLIP=true): bake the IN-BEAM CLIP image+text embedder
# (ONNX via Ortex + tokenizers + nx + stb_image — onnxruntime ~20 MB, no XLA, no
# JIT). mix.exs gates these deps AND host_ml/ on WB_CLIP=1, so the default build
# pulls NONE of it (lean image). When on, the deps + host_ml adapter compile into
# the release; route to it at runtime with WB_EMBED=clip.
ARG INCLUDE_CLIP=false
ENV WB_CLIP=""
COPY runtime/mix.exs runtime/mix.lock ./
RUN if [ "$INCLUDE_CLIP" = "true" ]; then export WB_CLIP=1; fi \
    && mix deps.get --only prod && mix deps.compile
COPY runtime/ .
RUN if [ "$INCLUDE_CLIP" = "true" ]; then export WB_CLIP=1; fi \
    && mix compile && mix release

# --- run ---------------------------------------------------------------------
FROM debian:bookworm-slim AS app
ENV LANG=C.UTF-8 WB_WEB=1 PORT=4000 WB_PROFILE_DIR=/opt/profile
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 ca-certificates curl xz-utils \
      git jq sqlite3 imagemagick \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://wasmtime.dev/install.sh | bash \
    && cp /root/.wasmtime/bin/wasmtime /usr/local/bin/wasmtime

# Bake the default semantic embedding model (Model2Vec/potion, ~30 MB) INTO the
# image — so the runtime never downloads it (no first-request stall, no
# per-restart re-pull, no volume dependency for the model). The runtime checks
# WB_MODELS_DIR before the WB_DATA cache.
ENV WB_MODELS_DIR=/opt/models
RUN mkdir -p /opt/models/potion-base-8M \
    && for f in config.json vocab.txt model.safetensors; do \
         curl -fsSL "https://huggingface.co/minishlab/potion-base-8M/resolve/main/$f" \
           -o "/opt/models/potion-base-8M/$f"; \
       done

# brandnana toolkit: the CLI binary + the agent profile (agents) + boards.
COPY --from=brandnana-cli /src/brandnana/apps/cli/dist/brandnana-linux-x64 /usr/local/bin/brandnana
COPY projects/brandnana/profile /opt/profile
COPY projects/brandnana/boards /opt/profile/boards

# IN-BEAM CLIP (opt-in, --build-arg INCLUDE_CLIP=true): bake the q8 ONNX towers +
# tokenizer (~147 MB) so the runtime never downloads them, and point the adapter at
# them via WB_CLIP_DIR. Skipped entirely on a lean build. Runtime route WB_EMBED=clip.
ARG INCLUDE_CLIP=false
ENV WB_CLIP_DIR=/opt/models/clip
RUN if [ "$INCLUDE_CLIP" = "true" ]; then \
      mkdir -p "$WB_CLIP_DIR" && cd "$WB_CLIP_DIR" \
      && base="https://huggingface.co/Xenova/clip-vit-base-patch32/resolve/main" \
      && curl -fsSL "$base/onnx/text_model_quantized.onnx"   -o text_model_quantized.onnx \
      && curl -fsSL "$base/onnx/vision_model_quantized.onnx" -o vision_model_quantized.onnx \
      && curl -fsSL "$base/tokenizer.json"                   -o tokenizer.json ; \
    fi
# Default (INCLUDE_CLIP=false): no image embedder — text-only semantic via the
# baked Model2Vec. Image embedding stays opt-in (also connectable as an external
# endpoint via WB_EMBED_IMAGE=http:<url>).

COPY --from=build /app/_build/prod/rel/workbooks ./
COPY --from=build /app/build ./build

EXPOSE 4000
CMD ["bin/workbooks", "start"]
