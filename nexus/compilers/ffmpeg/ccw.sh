#!/usr/bin/env bash
# ccw — a "cc" front-end that drives OUR in-sandbox clang.wasm (runs under wasmtime),
# so ffmpeg/x264 `configure` can run its cross-compile PROBES with zero host wasi-sdk.
#
# clang.wasm (yowasp llvm.core.wasm) is a MULTITOOL: the `clang` subcommand compiles, the
# `wasm-ld` subcommand links — but WASI can't spawn subprocesses, so the clang driver
# CANNOT invoke wasm-ld itself. So this wrapper splits the two:
#   * compile-only probe (-c / -E / -M...): one clang.wasm `clang` invocation.
#   * link probe (produces an executable): compile each .c -> .o with `clang`, then link the
#     .o set with `wasm-ld` (crt1 + libc + the requested -l libs). Matches ddb-link.sh.
#
# All probe files live in a FIXED scratch dir ($CCW_WORK, forced via configure --tempprefix /
# TMPDIR). We mount it /work and the clang sysroot /usr, rewriting every absolute arg under
# $CCW_WORK to its /work-relative guest path.
#
# Required env: CCW_CLANG (llvm.core.wasm), CCW_SYSROOT (clang-root sysroot), CCW_WORK (scratch).
# Optional:     CCW_EXTRA_DIRS = "host::guest[,host::guest...]" extra preopens (lib search dirs).
set -u
: "${CCW_CLANG:?}"; : "${CCW_SYSROOT:?}"; : "${CCW_WORK:?}"

work="$(cd "$CCW_WORK" && pwd)"
RTLIB=/usr/lib/wasm32-unknown-wasip1   # libclang_rt.builtins.a
LIBC=/usr/lib/wasm32-wasip1            # crt1 + libc + emulated libs

extra=()
if [ -n "${CCW_EXTRA_DIRS:-}" ]; then
  IFS=',' read -ra pairs <<< "$CCW_EXTRA_DIRS"
  for p in "${pairs[@]}"; do extra+=( --dir "$p" ); done
fi

# rewrite a host path under $work to a /work guest path (identity otherwise)
g() { case "$1" in "$work"/*) printf '/work/%s' "${1#$work/}";; "$work") printf '/work';; *) printf '%s' "$1";; esac; }

run_clang() {  # $@ = clang argv (already guest-translated)
  local t; t="$(mktemp -d)"
  wasmtime run -W exceptions=y -W memory64=y \
    --dir "$CCW_SYSROOT::/usr" --dir "$work::/work" --dir "$t::/tmp" --env TMPDIR=/tmp \
    ${extra[@]+"${extra[@]}"} "$CCW_CLANG" "$@"
  local rc=$?; rm -rf "$t"; return $rc
}

# --- classify the invocation -------------------------------------------------------------
compile_only=0; out=""; srcs=(); libs=(); libdirs=(); cflags=()
prev=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out="$(g "$a")"; prev=""; continue; fi
  case "$a" in
    -c|-E|-S|-M|-MM) compile_only=1; cflags+=( "$a" ) ;;
    -o) prev="-o" ;;
    -l*) libs+=( "$a" ) ;;
    -L*) libdirs+=( "$a" ) ;;
    *.c) srcs+=( "$(g "$a")" ) ;;
    *.o) srcs+=( "$(g "$a")" ) ;;
    --sysroot=*|--target=*) ;;   # we force our own
    *) cflags+=( "$(g "$a")" ) ;;
  esac
done

base=( clang --target=wasm32-wasip1 --sysroot=/usr )

if [ "$compile_only" = 1 ]; then
  argv=( "${base[@]}" ${cflags[@]+"${cflags[@]}"} ${libdirs[@]+"${libdirs[@]}"} )
  [ -n "$out" ] && argv+=( -o "$out" )
  argv+=( ${srcs[@]+"${srcs[@]}"} )
  run_clang "${argv[@]}"; exit $?
fi

# --- link probe: compile each .c -> .o, then wasm-ld ------------------------------------
objs=()
for s in ${srcs[@]+"${srcs[@]}"}; do
  case "$s" in
    *.o) objs+=( "$s" ) ;;
    *)   o="${s%.c}.ccw.o"
         run_clang "${base[@]}" ${cflags[@]+"${cflags[@]}"} -c "$s" -o "$o" || exit 1
         objs+=( "$o" ) ;;
  esac
done
[ -n "$out" ] || out="/work/a.out"

# translate -L dirs to guest paths
gldirs=()
for d in ${libdirs[@]+"${libdirs[@]}"}; do gldirs+=( "-L$(g "${d#-L}")" ); done

wasmtime run -W exceptions=y -W memory64=y \
  --dir "$CCW_SYSROOT::/usr" --dir "$work::/work" \
  ${extra[@]+"${extra[@]}"} \
  "$CCW_CLANG" wasm-ld -m wasm32 --error-limit=0 --allow-undefined \
    -L"$RTLIB" -L"$LIBC" ${gldirs[@]+"${gldirs[@]}"} \
    "$LIBC/crt1-command.o" \
    ${objs[@]+"${objs[@]}"} \
    ${libs[@]+"${libs[@]}"} \
    -lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-getpid -lwasi-emulated-mman \
    -lc "$RTLIB/libclang_rt.builtins.a" -lm \
    -o "$out"
