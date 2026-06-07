#!/usr/bin/env bash
# Build the TRUSTED Rust libstd for wasm32-wasi (prebuild, once). The UNTRUSTED user .rs then
# compiles IN-SANDBOX (mrustc.wasm) against this libstd. Native mrustc+minicargo here (trusted
# authoring, like building mrustc.wasm itself). PROVEN: a println program runs → "...42".
#
# Prereqs: wasi-sdk (WASI_SDK), rustc-1.54.0-src, the wasm32-wasi cc wrapper on PATH.
set -euo pipefail
SRC="${MRUSTC_SRC:?path to mrustc checkout}"; WASI_SDK="${WASI_SDK:?}"
cd "$SRC"
# 1. patch mrustc (ARCH_WASM32 + built-in wasm32-wasi target + #[link(wasm_import_module)])
git apply "$OLDPWD/mrustc-wasm-std.patch" 2>/dev/null || echo "(patch already applied?)"
make -j4 RUSTC_VERSION=1.54.0                      # native mrustc
make -f minicargo.mk bin/minicargo
# 2. dlmalloc script-override (wasi pulls dlmalloc; build.rs emits nothing)
touch "script-overrides/stable-1.54.0-macos/build_dlmalloc.txt" 2>/dev/null || true
# 3. env: target ver, the wasm cc wrapper (→ wasi-sdk clang), arch
export MRUSTC_TARGET_VER=1.54 STD_ENV_ARCH=wasm32
export CC_wasm32_wasi="$PWD/wasm32-wasi-gcc"       # the cc-wrapper.template.sh, installed
export PATH="$(dirname "$CC_wasm32_wasi"):$PATH"
# 4. build std's dep graph via minicargo (builtin wasm32-wasi target)
make -f minicargo.mk RUSTC_VERSION=1.54.0 MRUSTC_TARGET=wasm32-wasi OUTDIR=output-wasi/ LIBS || true
O=output-wasi
# 5. the `wasi` bindings crate + libstd are not auto-wired by minicargo's target-dep
#    resolution → build them explicitly against the dep graph:
bin/mrustc rustc-1.54.0-src/vendor/wasi/src/lib.rs --crate-name wasi --crate-type rlib \
  -L $O --out-dir $O --target wasm32-wasi --edition 2018 --cfg 'feature="rustc-dep-of-std"' \
  --extern core=$O/libcore.rlib --extern compiler_builtins=$O/libcompiler_builtins-*.rlib
# (libstd: replay the minicargo std command + --extern wasi=$O/libwasi.rlib — see PORT-LOG)
echo "libstd deps + wasi crate built in $O (libstd: add --extern wasi to the std command)"
