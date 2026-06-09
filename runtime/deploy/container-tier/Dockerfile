# Minimal Linux wasmtime image for the :container isolation tier (wb-kt6).
# Runs a command's .wasm in a throwaway container — kernel-level isolation.
FROM debian:stable-slim
ARG WASMTIME_VERSION=v27.0.0
RUN apt-get update && apt-get install -y --no-install-recommends curl xz-utils ca-certificates \
 && ARCH="$(dpkg --print-architecture)" \
 && case "$ARCH" in arm64) WT_ARCH=aarch64 ;; amd64) WT_ARCH=x86_64 ;; *) WT_ARCH="$ARCH" ;; esac \
 && curl -fsSL "https://github.com/bytecodealliance/wasmtime/releases/download/${WASMTIME_VERSION}/wasmtime-${WASMTIME_VERSION}-${WT_ARCH}-linux.tar.xz" \
    | tar xJ -C /usr/local/bin --strip-components=1 --wildcards '*/wasmtime' \
 && apt-get purge -y curl xz-utils && apt-get autoremove -y && rm -rf /var/lib/apt/lists/* \
 && wasmtime --version
ENTRYPOINT ["wasmtime"]
