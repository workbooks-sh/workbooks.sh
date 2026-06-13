#!/usr/bin/env bash
# Prebuild the TRUSTED Rust 1.74 SHARED-MEMORY THREADS libstd for wasm32-wasi-threads, ENTIRELY via
# mrustc.wasm + clang.wasm (keystone: multithreaded Rust). Sibling of prebuild-libstd-174.sh — same
# 1.74 plan + same mrustc.wasm (so the threads libstd is ABI/monomorph-hash consistent with user code
# compiled in the threads lane), with three deltas that turn on real OS threads:
#
#   1. STD PATCH: apply std/threads-patch (gate thread_local_key + locks on cfg(target_feature=atomics);
#      drop in thread_local_key_threads.rs — real pthread-backed TLS). Idempotent; pristine→patched.
#   2. --cfg target_feature=atomics on EVERY mrustc crate line. This is the no-fork bypass for the
#      mrustc target.cpp:746 `target_feature=false` hardcode: cfg.cpp checks CLI --cfg FIRST
#      (g_cfg_values), so cfg(target_feature="atomics") → true and the hardcoded callback is never
#      reached. target.cpp stays UNTOUCHED; the default wasm32-wasi (non-threads) lane is unaffected.
#   3. Compile each .rlib.c → .o with --target=wasm32-wasi-threads -pthread -matomics -mbulk-memory
#      (+ the same EH flags the 174 lane uses) → shared-memory atomics codegen.
#
# Output → output-wasi-174-threads/ (sibling of output-wasi-174/). CRITICAL: user code in the threads
# lane MUST link against THIS dir's .rlib.hir (std metadata) + .o — a base-vs-threads HIR mismatch
# yields undefined monomorph-hash symbols at link (e.g. spawn_unchecked __820 vs __880).
#
# Idempotent: skips if output-wasi-174-threads/libstd.rlib.o exists. Last stdout line = output dir.
set -euo pipefail

SD="$(cd "$(dirname "$0")" && pwd)"            # compilers/rust/std
RUST="$(cd "$SD/.." && pwd)"
COMPILERS="$(cd "$RUST/.." && pwd)"
MRDIR="$RUST/mrustc-root/mrustc"
MRWASM="${MRWASM:-$RUST/mrustc-root/mrustc_std.wasm}"
CLANG="${CLANG:-$COMPILERS/clang/clang-root/llvm.core.wasm}"
CSYS="${CSYS:-$COMPILERS/clang/clang-root/sysroot}"
WASI_SDK="${WASI_SDK:-$RUST/mrustc-root/wasi-sdk-33.0-arm64-macos}"
PLAN="$SD/std-build-plan-174.txt"             # reuse the 1.74 plan; rewrite output dir + add atomics cfg
STD_SRC="$MRDIR/rustc-1.74.0-src/library/std/src/sys/wasi"
O="output-wasi-174-threads"

exec 3>&1 1>&2

for f in "$MRWASM" "$CLANG" "$PLAN" "$WASI_SDK/bin/llvm-ar"; do
  [ -e "$f" ] || { echo "[libstd174-threads] MISSING input: $f"; exit 1; }
done
[ -d "$CSYS/lib" ] || { echo "[libstd174-threads] clang sysroot not built: $CSYS"; exit 1; }
[ -d "$STD_SRC" ] || { echo "[libstd174-threads] std source not extracted: $STD_SRC (run provision-rust-174.sh)"; exit 1; }

# 0. apply the std threads patch (idempotent) — gates TLS/locks on atomics + adds real pthread TLS.
python3 "$SD/threads-patch/apply-std-threads-patch.py" "$STD_SRC"

cd "$MRDIR"
mkdir -p "$O" "$O/host" .mrtmp .cctmp

if [ -f "$O/libstd.rlib.o" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "[libstd174-threads] already built; skip (FORCE=1 to rebuild)"; echo "$MRDIR/$O" 1>&3; exit 0
fi
if [ "${FORCE:-0}" = "1" ]; then
  echo "[libstd174-threads] FORCE: clearing $O"; rm -rf "${MRDIR:?}/$O"; mkdir -p "$O" "$O/host"
fi

MR(){ wasmtime run -W exceptions=y -W max-wasm-stack=536870912 \
      --env MRUSTC_TARGET_VER=1.74 --env STD_ENV_ARCH=wasm32 --env TMPDIR=/tmp \
      --dir "$MRDIR::." --dir "$MRDIR/.mrtmp::/tmp" "$MRWASM" "$@"; }
# Compile std .rlib.c → .o with shared-memory atomics codegen (wasm32-wasi-threads) + the 174 EH flags.
CL(){ wasmtime run -W exceptions=y \
      --dir "$CSYS::/usr" --dir "$MRDIR::/work" --dir "$MRDIR/.cctmp::/tmp" --env TMPDIR=/tmp \
      "$CLANG" clang --target=wasm32-wasi-threads --sysroot=/usr -pthread -matomics -mbulk-memory \
      -O1 -fno-strict-aliasing -w \
      -fwasm-exceptions -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false \
      -Xclang -disable-llvm-verifier "$@"; }

crate(){  # $1 = label, $2.. = mrustc args (already rewritten to output-wasi-174-threads + atomics cfg)
  local label="$1"; shift
  local out; out="$(printf '%s ' "$@" | grep -oE '\-o [^ ]+' | head -1 | awk '{print $2}' || true)"
  echo "[libstd174-threads] $label → $(basename "${out:-?}")"
  MR "$@"
  if [ -n "$out" ] && [ -f "$out.c" ]; then
    CL -c "/work/$out.c" -o "/work/$out.o"
    "$WASI_SDK/bin/llvm-ar" rcs "$out" "$out.o" 2>/dev/null || true
  else
    echo "[libstd174-threads] WARN: no $out.c emitted for $label"
  fi
}

n=0
while IFS= read -r line; do
  [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ] && continue
  n=$((n+1))
  # Rewrite the base plan for the threads lane: output dir + the atomics cfg bypass on EVERY line
  # (std AND its build deps — they all must agree on target_feature=atomics for ABI consistency).
  tline="${line//output-wasi-174/output-wasi-174-threads} --cfg target_feature=atomics"
  # shellcheck disable=SC2086
  crate "[$n]" $tline
done < "$PLAN"

[ -f "$O/libstd.rlib.o" ] || { echo "[libstd174-threads] FAILED: no libstd.rlib.o produced"; exit 1; }
echo "[libstd174-threads] DONE — $(ls "$O"/*.rlib.o | wc -l | xargs) crate objects in $O"
echo "$MRDIR/$O" 1>&3
