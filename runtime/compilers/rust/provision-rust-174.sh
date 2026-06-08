#!/usr/bin/env bash
# KEYSTONE (bd wb-bdk): provision the Rust 1.74 lane to RAISE the mrustc ceiling 1.54 → 1.74,
# which unblocks proc-macro derive (syn compiles) + full unicode tables. Our mrustc checkout
# (v0.12.0-40) already supports RUSTC_VERSION=1.74.0; this recipe stands up the 1.74 inputs and
# builds a 1.74 libstd, kept SEPARATE from the working 1.54 lane (output-wasi-174/) so a failed
# 1.74 experiment never breaks the proven 1.54 path. Idempotent: fast-skips completed stages.
#
# Run from a fresh checkout AFTER provision-rust.sh (reuses native mrustc+minicargo+clang.wasm).
set -euo pipefail
say(){ echo "[prov-174] $*" >&2; }

SD="$(cd "$(dirname "$0")" && pwd)"            # compilers/rust
MR="$SD/mrustc-root/mrustc"
VER=1.74.0

# 1. rustc-1.74.0-src (the libstd source mrustc compiles). ~2.3G extracted; mrustc auto-patches it.
if [ ! -e "$MR/rustc-$VER-src/library/std/src/lib.rs" ]; then
  say "fetching rustc-$VER-src (long ~280MB download + extract)"
  ( cd "$MR" && make -f minicargo.mk RUSTCSRC RUSTC_VERSION=$VER >&2 )
else say "rustc-$VER-src present — skip"; fi

# 2. macOS build-script overrides for 1.74. UPSTREAM GAP: mrustc ships stable-1.74.0-{linux,windows}
#    but NOT -macos (our host). Synthesize it from 1.74-linux with the one macOS-relevant delta the
#    1.54 macos/linux pair shows: libc's host cfg freebsd11 → darwin. (STD_ENV_ARCH is overridden to
#    wasm32 at build time; unwind emits nothing on macos.) Without this, minicargo can't resolve the
#    build-script output dir for the host on 1.74.
OVR="$MR/script-overrides"
if [ ! -e "$OVR/stable-$VER-macos/build_libc.txt" ]; then
  say "synthesizing stable-$VER-macos script-overrides (upstream ships linux/windows only)"
  DST="$OVR/stable-$VER-macos"; mkdir -p "$DST"
  cp "$OVR/stable-$VER-linux/build_compiler_builtins.txt" "$DST/"
  cp "$OVR/stable-$VER-linux/build_std.txt" "$DST/"
  cp "$OVR/stable-$VER-linux/build_unwind.txt" "$DST/"   # empty; macos unwind build-script emits nothing
  sed 's/^cargo:rustc-cfg=freebsd11$/cargo:rustc-cfg=darwin/' \
      "$OVR/stable-$VER-linux/build_libc.txt" > "$DST/build_libc.txt"
else say "stable-$VER-macos overrides present — skip"; fi

# 3. native 1.74 libstd build via minicargo (cross to wasm32-wasi) → output-wasi-174/.
#    This both VALIDATES native 1.74 support and (via captured per-crate mrustc invocations)
#    yields the plan replayed through mrustc.wasm for the ABI-consistent sandbox libstd.
if [ ! -f "$MR/output-wasi-174/libstd.rlib.o" ]; then
  say "prebuilding 1.74 libstd via mrustc.wasm (long)"; bash "$SD/std/prebuild-libstd-174.sh" >&2
else say "1.74 libstd prebuilt — skip"; fi

say "1.74 inputs staged (src + macos overrides). Next: native libstd build + wasm replay."
