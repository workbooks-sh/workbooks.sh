# Ether — FP-Q4 track: mainline llama.cpp + Granite 4.1 (3B + 8B) Q4_K_M, slim multi-stage.
# Granite 4.1 uses hybrid Mamba-2 layers, so it needs a CURRENT llama.cpp (the bitnet.cpp fork
# is too old) — bench.sh smoke-tests that the GGUF actually loads. Models are fetched on the
# machine (fetch-granite.sh), not baked, so the pushed image stays small.
FROM ubuntu:24.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      git cmake build-essential libgomp1 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt
RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp.git llama
WORKDIR /opt/llama

# Portable build (GGML_NATIVE=OFF -> AVX2 baseline) so it can't fault on an older Fly CPU.
# -j 2 keeps peak compiler RAM under the builder cap (per-model .cpp TUs OOM at unlimited -j).
RUN cmake -B build -DGGML_NATIVE=OFF -DGGML_OPENMP=ON -DLLAMA_CURL=OFF -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build --config Release -j 2 --target llama-bench llama-cli llama-server

# ---- final: binaries + the 3B model BAKED IN (so cold-start = boot + load, no download) ----
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgomp1 libstdc++6 curl ca-certificates bc vmtouch \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /opt/llama/build /opt/llama/build
# Bake Granite-3B-Q4 (~2GB) into the image rootfs — this is the realistic per-invocation deploy.
RUN mkdir -p /models \
    && curl -fL https://huggingface.co/ibm-granite/granite-4.1-3b-GGUF/resolve/main/granite-4.1-3b-Q4_K_M.gguf \
         -o /models/granite-4.1-3b-Q4_K_M.gguf
COPY bench.sh /opt/llama/bench.sh
COPY fetch-granite.sh /opt/llama/fetch-granite.sh
COPY coldstart-entry.sh /opt/coldstart-entry.sh
RUN chmod +x /opt/llama/*.sh /opt/coldstart-entry.sh
WORKDIR /opt/llama
# On boot: time cold model-load + first tokens, log it, then stay up for inspection.
CMD ["/opt/coldstart-entry.sh"]
