#!/usr/bin/env bash
# ONE idempotent entrypoint that rebuilds the entire Rust-in-WASM lane from the committed
# recipe. Run this in any fresh checkout (or after the gitignored artifacts are cleaned) and
# it brings the lane back to "untrusted Rust+std compiles in the sandbox". Fast-skips every
# stage whose output already exists, so it's cheap to re-run as a status check. See BUILD-STATE.org.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"          # compilers/rust
COMPILERS="$(cd "$SD/.." && pwd)"
MR="$SD/mrustc-root/mrustc"
say(){ echo "[provision-rust] $*" >&2; }

# 1. clang.wasm + sysroot (the C backend that finishes the Rust chain)
if [ ! -f "$COMPILERS/clang/clang-root/llvm.core.wasm" ]; then
  say "building clang.wasm lane"; bash "$COMPILERS/clang/build.sh" >&2
else say "clang.wasm present — skip"; fi

# 1b. mrustc C-backend patch: lower the `llvm.wasm.*` intrinsics (rayon futex park/wake + wasm
#     SIMD) that mrustc's codegen_c.cpp otherwise aborts on. Idempotent; MUST run before ANY
#     mrustc compile (both mrustc.wasm via build.sh AND the native make below).
say "applying mrustc codegen patch (wasm futex + SIMD intrinsics)"
python3 "$SD/mrustc-patch/apply-mrustc-codegen-patch.py" "$MR/src/trans/codegen_c.cpp" >&2

# 2. mrustc.wasm (no_std) + std-patched mrustc_std.wasm (the -O1 build; -O0 is broken)
if [ ! -f "$SD/mrustc-root/mrustc_std.wasm" ]; then
  say "building mrustc.wasm + applying std patch + mrustc_std.wasm"
  ( cd "$MR" && git apply --check "$SD/std/mrustc-wasm-std.patch" 2>/dev/null && \
      git apply "$SD/std/mrustc-wasm-std.patch" || true )   # idempotent: skip if already applied
  bash "$SD/build.sh" >&2
  cp "$SD/mrustc-root/mrustc.wasm" "$SD/mrustc-root/mrustc_std.wasm"
else say "mrustc_std.wasm present — skip"; fi

# 3. native mrustc + minicargo + rustc-1.54.0-src (drives/sources the libstd prebuild)
if [ ! -x "$MR/bin/minicargo" ]; then
  say "building native mrustc + minicargo"; ( cd "$MR" && make -j4 RUSTC_VERSION=1.54.0 >&2 && \
    make -f minicargo.mk bin/minicargo RUSTC_VERSION=1.54.0 >&2 )
else say "minicargo present — skip"; fi
if [ ! -e "$MR/rustc-1.54.0-src/library/std/src/lib.rs" ]; then
  say "fetching rustc-1.54.0-src"; ( cd "$MR" && make -f minicargo.mk RUSTCSRC RUSTC_VERSION=1.54.0 >&2 )
else say "rustc-1.54.0-src present — skip"; fi

# 4. the 1.54 libstd prebuild (built entirely BY mrustc.wasm — hash/ABI consistent).
#    NOTE: the RUNTIME uses only the 1.74 lane (output-wasi-174); this 1.54 libstd (output-wasi/)
#    backs the legacy proof scripts (e2e.sh / multicrate-e2e.sh) ONLY. WB_SKIP_154_LIBSTD=1 skips
#    it — the path provision-runtime.sh takes (saves the long build for runtime/CI provisioning).
if [ "${WB_SKIP_154_LIBSTD:-0}" = "1" ]; then
  say "skipping 1.54 libstd (runtime uses the 1.74 lane only)"
elif [ ! -f "$MR/output-wasi/libstd.rlib.o" ]; then
  say "prebuilding libstd via mrustc.wasm (long)"; bash "$SD/std/prebuild-libstd.sh" >&2
else say "libstd prebuilt — skip"; fi

say "DONE — Rust-in-WASM lane provisioned."
