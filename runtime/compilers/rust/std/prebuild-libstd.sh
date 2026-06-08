#!/usr/bin/env bash
# Prebuild the TRUSTED Rust libstd for wasm32-wasi ENTIRELY via mrustc.wasm + clang.wasm
# (wb-fm0.3 / wb-zyl.8 iter 24). One-time. Untrusted user .rs then compiles IN-SANDBOX
# against this libstd. The whole reason it must be built by mrustc.wasm (not native): the
# .hir embeds C++ libc++ inline-namespace types (__2 for wasi-sdk libc++) and mrustc.wasm
# only reads __2; AND monomorphization hashes differ native-vs-wasm, so user .o + libstd .o
# must come from the SAME mrustc. So every crate here is compiled by mrustc.wasm.
#
# Replays the captured per-crate command sequence (std-build-plan.txt — 17 crates, core →
# … → std) through the wrapper: mrustc.wasm emits .c + .hir, clang.wasm compiles .c → .o
# (libstd's synthesized abort_bitcast trips clang's verifier with a spurious 'signext on
# incompatible type' — signext is a no-op on wasm — so ALL crates compile with
# -Xclang -disable-llvm-verifier), llvm-ar packages the .o into the .rlib.
#
# Idempotent: skips if output-wasi/libstd.rlib.o already exists. Contract: last stdout line
# = the absolute output-wasi dir (the libstd the per-program lane links against).
set -euo pipefail

SD="$(cd "$(dirname "$0")" && pwd)"            # compilers/rust/std
RUST="$(cd "$SD/.." && pwd)"                   # compilers/rust
COMPILERS="$(cd "$RUST/.." && pwd)"            # compilers
MRDIR="$RUST/mrustc-root/mrustc"               # mrustc checkout = the single wasm preopen
MRWASM="${MRWASM:-$RUST/mrustc-root/mrustc_std.wasm}"   # std-patched mrustc.wasm (-O1)
CLANG="${CLANG:-$COMPILERS/clang/clang-root/llvm.core.wasm}"
CSYS="${CSYS:-$COMPILERS/clang/clang-root/sysroot}"
WASI_SDK="${WASI_SDK:-$RUST/mrustc-root/wasi-sdk-33.0-arm64-macos}"
PLAN="$SD/std-build-plan.txt"
O="output-wasi"                                # relative to MRDIR (the preopen)

exec 3>&1 1>&2                                 # progress → stderr; fd 3 = the one stdout line

for f in "$MRWASM" "$CLANG" "$PLAN" "$WASI_SDK/bin/llvm-ar"; do
  [ -e "$f" ] || { echo "[libstd] MISSING input: $f"; exit 1; }
done
[ -d "$CSYS/lib" ] || { echo "[libstd] clang sysroot not built: $CSYS"; exit 1; }

cd "$MRDIR"
mkdir -p "$O" .mrtmp .cctmp

if [ -f "$O/libstd.rlib.o" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "[libstd] already built ($O/libstd.rlib.o); skip (FORCE=1 to rebuild)"
  echo "$MRDIR/$O" 1>&3; exit 0
fi

# mrustc.wasm: single preopen = the mrustc dir (so rustc-1.54.0-src/… and output-wasi/… resolve).
MR(){ wasmtime run -W exceptions=y \
      --env MRUSTC_TARGET_VER=1.54 --env STD_ENV_ARCH=wasm32 --env TMPDIR=/tmp \
      --dir "$MRDIR::." --dir "$MRDIR/.mrtmp::/tmp" "$MRWASM" "$@"; }
# clang.wasm: /usr=sysroot, /work=mrustc dir. -disable-llvm-verifier for the abort_bitcast wall.
CL(){ wasmtime run -W exceptions=y \
      --dir "$CSYS::/usr" --dir "$MRDIR::/work" --dir "$MRDIR/.cctmp::/tmp" --env TMPDIR=/tmp \
      "$CLANG" clang --target=wasm32-wasip1 --sysroot=/usr -O1 -fno-strict-aliasing -w \
      -fwasm-exceptions -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false \
      -Xclang -disable-llvm-verifier "$@"; }

# Compile one mrustc-emitted crate: mrustc.wasm <args> → .c+.hir, clang.wasm .c→.o, ar into .rlib.
crate(){  # $1 = label, $2.. = mrustc args
  local label="$1"; shift
  local out; out="$(printf '%s ' "$@" | grep -oE '\-o [^ ]+' | head -1 | awk '{print $2}')"
  echo "[libstd] $label → $(basename "${out:-?}")"
  MR "$@"
  if [ -n "$out" ] && [ -f "$out.c" ]; then
    CL -c "/work/$out.c" -o "/work/$out.o"
    "$WASI_SDK/bin/llvm-ar" rcs "$out" "$out.o" 2>/dev/null || true
  else
    echo "[libstd] WARN: no $out.c emitted for $label"
  fi
}

n=0
while IFS= read -r raw; do
  line="$(printf '%s' "$raw" | sed -e 's#/private/tmp/mr/mrustc/##g' -e 's#/tmp/mr/mrustc/##g')"
  [ -z "$(printf '%s' "$line" | tr -d '[:space:]')" ] && continue
  n=$((n+1))

  # CRITICAL (wb-fm0.3 / PORT-LOG iter 26): minicargo's captured plan OMITS the `wasi` target-dep,
  # but libstd's os/wasi module references the `wasi` crate (else mrustc aborts "Couldn't find
  # path component 'wasi'"). So right before the libstd crate, build wasi and add --extern wasi.
  if printf '%s' "$line" | grep -q 'library/std/src/lib.rs'; then
    if [ ! -f "$O/libwasi.rlib.o" ]; then
      CB="$(ls "$O"/libcompiler_builtins-*.rlib | head -1)"
      crate "[wasi]" rustc-1.54.0-src/vendor/wasi/src/lib.rs --crate-name wasi --crate-type rlib \
        -L "$O" --out-dir "$O" --target wasm32-wasi --edition 2018 --cfg 'feature=rustc-dep-of-std' \
        --extern core="$O/libcore.rlib" --extern compiler_builtins="$CB"
    fi
    line="$line --extern wasi=$O/libwasi.rlib"
  fi

  # shellcheck disable=SC2086
  crate "[$n]" $line
done < "$PLAN"

# ABI sanity: libcore's .hir must be the wasm libc++ __2 namespace (else mrustc.wasm can't read it).
if [ -f "$O/libcore.rlib.hir" ] && ! grep -qa '__2' "$O/libcore.rlib.hir"; then
  echo "[libstd] WARN: libcore.rlib.hir has no __2 marker — ABI may be inconsistent"
fi

[ -f "$O/libstd.rlib.o" ] || { echo "[libstd] FAILED: no libstd.rlib.o produced"; exit 1; }
echo "[libstd] DONE — $(ls "$O"/*.rlib.o | wc -l | xargs) crate objects in $O"
echo "$MRDIR/$O" 1>&3
