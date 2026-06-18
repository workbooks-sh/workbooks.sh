#!/usr/bin/env bash
# Prebuild the TRUSTED Rust 1.74 libstd for wasm32-wasi ENTIRELY via mrustc.wasm + clang.wasm
# (keystone wb-bdk / wb-lu5). Replays std-build-plan-174.txt (24 crate cmds captured from native
# minicargo) through the SAME mrustc.wasm that compiles untrusted user code → ABI/monomorph-hash
# consistent, so user .o links against this libstd. Mirrors prebuild-libstd.sh but for 1.74:
#   - MRUSTC_TARGET_VER=1.74, output dir output-wasi-174/, edition is per-cmd in the plan
#   - plan is SELF-CONTAINED (wasi crate included; no manual inject vs 1.54)
#   - NO hashbrown debug-assert neuter: 1.74 hashbrown-0.14 compiles clean (the 3 mrustc fixes —
#     family=wasm, arith_offset, ptr_guaranteed_cmp — cleared it).
# Idempotent: skips if output-wasi-174/libstd.rlib.o exists. Last stdout line = output dir.
set -euo pipefail

SD="$(cd "$(dirname "$0")" && pwd)"            # compilers/rust/std
RUST="$(cd "$SD/.." && pwd)"
COMPILERS="$(cd "$RUST/.." && pwd)"
MRDIR="$RUST/mrustc-root/mrustc"
MRWASM="${MRWASM:-$RUST/mrustc-root/mrustc_std.wasm}"
CLANG="${CLANG:-$COMPILERS/clang/clang-root/llvm.core.wasm}"
CSYS="${CSYS:-$COMPILERS/clang/clang-root/sysroot}"
WASI_SDK="${WASI_SDK:-$RUST/mrustc-root/wasi-sdk-33.0-arm64-macos}"
PLAN="$SD/std-build-plan-174.txt"
O="output-wasi-174"

exec 3>&1 1>&2

for f in "$MRWASM" "$CLANG" "$PLAN" "$WASI_SDK/bin/llvm-ar"; do
  [ -e "$f" ] || { echo "[libstd174] MISSING input: $f"; exit 1; }
done
[ -d "$CSYS/lib" ] || { echo "[libstd174] clang sysroot not built: $CSYS"; exit 1; }

cd "$MRDIR"
mkdir -p "$O" "$O/host" .mrtmp .cctmp

if [ -f "$O/libstd.rlib.o" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "[libstd174] already built; skip (FORCE=1 to rebuild)"; echo "$MRDIR/$O" 1>&3; exit 0
fi
if [ "${FORCE:-0}" = "1" ]; then
  echo "[libstd174] FORCE: clearing $O"; rm -rf "${MRDIR:?}/$O"; mkdir -p "$O" "$O/host"
fi

MR(){ wasmtime run -W exceptions=y -W max-wasm-stack=536870912 \
      --env MRUSTC_TARGET_VER=1.74 --env STD_ENV_ARCH=wasm32 --env TMPDIR=/tmp \
      --dir "$MRDIR::." --dir "$MRDIR/.mrtmp::/tmp" "$MRWASM" "$@"; }
CL(){ wasmtime run -W exceptions=y \
      --dir "$CSYS::/usr" --dir "$MRDIR::/work" --dir "$MRDIR/.cctmp::/tmp" --env TMPDIR=/tmp \
      "$CLANG" clang --target=wasm32-wasip1 --sysroot=/usr -O1 -fno-strict-aliasing -w \
      -fwasm-exceptions -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false \
      -Xclang -disable-llvm-verifier "$@"; }

crate(){  # $1 = label, $2.. = mrustc args (incl `-o output-wasi-174/libNAME.rlib`)
  local label="$1"; shift
  local out; out="$(printf '%s ' "$@" | grep -oE '\-o [^ ]+' | head -1 | awk '{print $2}' || true)"
  echo "[libstd174] $label → $(basename "${out:-?}")"
  MR "$@"
  if [ -n "$out" ] && [ -f "$out.c" ]; then
    CL -c "/work/$out.c" -o "/work/$out.o"
    "$WASI_SDK/bin/llvm-ar" rcs "$out" "$out.o" 2>/dev/null || true
  else
    echo "[libstd174] WARN: no $out.c emitted for $label"
  fi
}

n=0
while IFS= read -r line; do
  [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ] && continue
  n=$((n+1))
  # shellcheck disable=SC2086
  crate "[$n]" $line
done < "$PLAN"

[ -f "$O/libstd.rlib.o" ] || { echo "[libstd174] FAILED: no libstd.rlib.o produced"; exit 1; }
echo "[libstd174] DONE — $(ls "$O"/*.rlib.o | wc -l | xargs) crate objects in $O"
echo "$MRDIR/$O" 1>&3
