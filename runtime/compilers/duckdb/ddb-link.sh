#!/bin/zsh
# Link all DuckDB .o + driver into duckdb.wasm, mirroring compilers.ex compile_c link.
set -u
RT=/Users/shinyobjectz/Apps/workbooks/runtime
CLANG=$RT/compilers/clang/clang-root/llvm.core.wasm
SYSROOT=$RT/compilers/clang/clang-root/sysroot
BD=/tmp/duckdb-build
RTLIB=/usr/lib/wasm32-unknown-wasip1   # @clang_lib_rt (guest)
LIBC=/usr/lib/wasm32-wasip1            # @clang_lib_c  (guest)

# All object files as guest /work paths.
OBJS=()
for o in $BD/*.o; do OBJS+=(/work/${o:t}); done

wasmtime -W exceptions=y -W memory64=y \
  --dir $SYSROOT::/usr --dir $BD::/work \
  $CLANG wasm-ld -m wasm32 --error-limit=0 --allow-multiple-definition -z stack-size=8388608 \
    -L$RTLIB -L$LIBC \
    --wrap=mmap --wrap=munmap --wrap=msync \
    $LIBC/crt1-command.o \
    "${OBJS[@]}" \
    -lsetjmp \
    -lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-getpid \
    -lwasi-emulated-mman \
    -lc++ $LIBC/libc++abi-eh.a $LIBC/libunwind-eh.a \
    -lc $RTLIB/libclang_rt.builtins.a \
    -o /work/duckdb.wasm \
  2>&1 | tail -40
echo "=== duckdb.wasm: $([[ -f $BD/duckdb.wasm ]] && ls -la $BD/duckdb.wasm || echo MISSING)"
