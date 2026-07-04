#!/bin/sh
# Build the Zig toolchain REACTOR and stage it into nexus/priv so `mix release` / the OCI image bundle
# it. `Nexus.Toolchain` loads priv/work-toolchain.wasm at runtime — without this step it isn't there in
# a fresh build. Run before `mix release` / `docker build` (CI installs zig 0.16; see nexus-image.yml).
#   nexus/scripts/stage-cli.sh
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
command -v zig >/dev/null 2>&1 || { echo "[stage-cli] zig not found (need 0.16) — skipping" >&2; exit 0; }
cd "$ROOT/reactor"
zig build reactor
mkdir -p "$ROOT/nexus/priv"
cp -f zig-out/bin/work-toolchain.wasm "$ROOT/nexus/priv/work-toolchain.wasm"
echo "[stage-cli] staged work-toolchain.wasm → nexus/priv ($(du -h "$ROOT/nexus/priv/work-toolchain.wasm" | cut -f1))"
