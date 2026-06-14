#!/bin/zsh
# One-shot DuckDB TU builder (uniquely named; do not auto-rerun).
set -u
RT=/Users/shinyobjectz/Apps/workbooks/runtime
CLANG=$RT/compilers/clang/clang-root/llvm.core.wasm
SYSROOT=$RT/compilers/clang/clang-root/sysroot
BD=/tmp/duckdb-build
mkdir -p $BD/log
CFLAGS=(
  --target=wasm32-wasip1 --sysroot=/usr -O2
  -fwasm-exceptions -mllvm -wasm-use-legacy-eh=false -mllvm -wasm-enable-sjlj
  -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID
  -D_WASI_EMULATED_MMAN -DL_tmpnam=260 -DDUCKDB_AMALGAMATION -DNDEBUG
  -DF_RDLCK=0 -DF_WRLCK=1 -DF_UNLCK=2 -DF_GETLK=5 -DF_SETLK=6 -DF_SETLKW=7
  '-Dsched_getcpu()=0'
  '-Dwinsize=winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; }'
  '-DTIOCGWINSZ=0x5413'
)
OK=0; TOTAL=0; FAILED=()
for cpp in $BD/*.cpp; do
  tu=${cpp:t:r}; o=$BD/$tu.o; TOTAL=$((TOTAL+1))
  if [[ -f $o && $o -nt $cpp && $o -nt $BD/duckdb-internal.hpp ]]; then
    echo "SKIP  $tu"; OK=$((OK+1)); continue
  fi
  echo "BUILD $tu ..."
  wasmtime -W exceptions=y -W memory64=y --dir $SYSROOT::/usr --dir $BD::/work \
    $CLANG clang "${CFLAGS[@]}" -c /work/$tu.cpp -o /work/$tu.o 2> $BD/log/$tu.err
  if [[ -f $o ]]; then echo "  OK   $tu"; OK=$((OK+1)); else echo "  FAIL $tu"; FAILED+=($tu); fi
done
echo "RESULT OK=$OK / $TOTAL"
(( ${#FAILED} )) && echo "FAILEDLIST: ${FAILED[@]}"
echo "ALLDONE"
