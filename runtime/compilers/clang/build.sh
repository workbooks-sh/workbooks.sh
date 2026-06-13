#!/usr/bin/env bash
# Provision the clang/lld compiler-in-wasm: YoWASP's LLVM built FOR wasm32-wasi (runs on
# wasmtime). We do NOT build LLVM — we fetch + sha-verify the prebuilt npm package and
# extract llvm.core.wasm (the clang+lld multitool) + its sysroot (libc/headers/builtins).
#
# This is the ONLY mature full-C→wasm compiler that runs in the sandbox (tcc/chibicc/c4
# emit native or interpret a subset — they cannot emit wasm). It is the production C lane
# and the backend that finishes Zig (.zig→C via zig1.wasm, then C→wasm here).
#
# Contract (build_and_register_script): last stdout line = the wasm path; progress → stderr.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SD/clang-root"
CORE="$ROOT/llvm.core.wasm"
VERSION="22.0.0-git20542-10"
SHA=6230ea1afa9691fa065935cf68c01642ff9b31c183fe8ac64cdfda025df06009
URL="https://registry.npmjs.org/@yowasp/clang/-/clang-${VERSION}.tgz"

exec 3>&1 1>&2   # progress → stderr; fd 3 = the one stdout line (the wasm path)

if [ ! -f "$CORE" ]; then
  TARB="$SD/clang-${VERSION}.tgz"
  if [ ! -f "$TARB" ]; then
    echo "[clang] fetching $URL"
    curl -fsSL -o "$TARB" "$URL"
  fi
  echo "[clang] verifying sha256"
  echo "$SHA  $TARB" | shasum -a 256 -c - || { echo "[clang] SHA MISMATCH — refusing"; exit 1; }
  echo "[clang] extracting → $ROOT"
  rm -rf "$ROOT"; mkdir -p "$ROOT/sysroot"
  tar -xzf "$TARB" -C "$ROOT" --strip-components=2 package/gen/llvm.core.wasm package/gen/llvm-resources.tar
  # The sysroot (include/ lib/ share/) mounts at the clang resource-dir /usr at run time.
  tar -xf "$ROOT/llvm-resources.tar" -C "$ROOT/sysroot"
  rm -f "$ROOT/llvm-resources.tar"
fi

# wb: wasm32-wasi-threads OVERLAY (shared-memory pthreads). The yowasp package ships only wasm32-wasip1, so we
# overlay the threads libc/crt/headers from the wasi-sdk sysroot package — enabling Compilers.compile_threads.
# Additive + idempotent (skips if already present), so it lands on fresh AND already-provisioned roots.
THR_URL="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-25/wasi-sysroot-25.0.tar.gz"
THR_SHA="d09c62c18efcddffe4b2fdd8c5830109cc8e36130cdbc9acdc0bd1b204c942bb"
if [ -d "$ROOT/sysroot/lib" ] && [ ! -d "$ROOT/sysroot/lib/wasm32-wasi-threads" ]; then
  TTH="$SD/wasi-sysroot-25.0.tar.gz"
  if [ ! -f "$TTH" ]; then echo "[clang] fetching wasm32-wasi-threads sysroot"; curl -fsSL -o "$TTH" "$THR_URL"; fi
  echo "$THR_SHA  $TTH" | shasum -a 256 -c - || { echo "[clang] threads sysroot SHA MISMATCH — refusing"; exit 1; }
  echo "[clang] overlaying wasm32-wasi-threads sysroot"
  THRTMP="$SD/.thr-tmp"; rm -rf "$THRTMP"; mkdir -p "$THRTMP"
  tar -xzf "$TTH" -C "$THRTMP"
  cp -R "$THRTMP/wasi-sysroot-25.0/lib/wasm32-wasi-threads" "$ROOT/sysroot/lib/"
  cp -R "$THRTMP/wasi-sysroot-25.0/include/wasm32-wasi-threads" "$ROOT/sysroot/include/"
  rm -rf "$THRTMP"
fi

# wb: C++ EXCEPTIONS OVERLAY (new standardized EH — try_table/exnref, the only kind wasmtime 45 `-W exceptions=y`
# supports). The vendored libc++abi.a is a NO-EXCEPTIONS build, so compile_cpp(exceptions: true) needs EH-enabled
# archives. We build them IN-SANDBOX (clang.wasm, zero native toolchain) from llvmorg-22.1.0 sources matched to the
# installed libc++ (22.1.0) — 5 libc++abi EH objects + 1 libunwind C object + the __cpp_exception TAG keystone —
# then assemble two `-eh` archives into the sysroot. The archives are GITIGNORED build artifacts (re)produced here.
# Mirrors the threads overlay: additive + idempotent (skips if archives already present). Single-threaded
# (wasm32-wasip1/no-threads) — the wasm32-wasi-threads lane would need its own EH archive built the same way.
EHDIR="$ROOT/sysroot/lib/wasm32-wasip1"
if [ -f "$CORE" ] && [ -d "$EHDIR" ] && { [ ! -f "$EHDIR/libc++abi-eh.a" ] || [ ! -f "$EHDIR/libunwind-eh.a" ]; }; then
  echo "[clang] building C++ exceptions (-eh) archives in-sandbox"
  EHTAG="llvmorg-22.1.0"
  EHBASE="https://raw.githubusercontent.com/llvm/llvm-project/${EHTAG}"
  EHTMP="$SD/.eh-tmp"; rm -rf "$EHTMP"
  # build trees: A = libc++abi sources (/work), U = libunwind C source (/work), AR = archive assembly
  A="$EHTMP/abi"; U="$EHTMP/unw"; G="$EHTMP/tag"; AR="$EHTMP/ar"
  mkdir -p "$A/include" "$U" "$G" "$AR"

  # fetch + verify one file: fetch <relpath-in-repo> <dest> <sha256>
  ehfetch() {
    local rel="$1" dst="$2" want="$3"
    curl -fsSL -o "$dst" "$EHBASE/$rel" || { echo "[clang] EH fetch FAILED: $rel"; exit 1; }
    local got; got="$(shasum -a 256 "$dst" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || { echo "[clang] EH SHA MISMATCH for $rel: $got != $want — refusing"; exit 1; }
  }

  # --- libc++abi EH sources (staged into /work=$A) ---
  ehfetch libcxxabi/src/cxa_exception.cpp         "$A/cxa_exception.cpp"         1feb758c547d8ddc2f4f3a08fe9fde586bba55649dd30e13191659d807093e19
  ehfetch libcxxabi/src/cxa_exception_storage.cpp "$A/cxa_exception_storage.cpp" 7de17cefbedbf94d7282fe3cde0e23e592b90c1d5e50db5d63009d7cfc877721
  ehfetch libcxxabi/src/fallback_malloc.cpp       "$A/fallback_malloc.cpp"       561b22a242cb96f40d80f77ecb216050bf434c24a8af8fc27e8ee61111497741
  ehfetch libcxxabi/src/cxa_personality.cpp       "$A/cxa_personality.cpp"       d9d82c76d99df2a9850125287fb0ad2f5e3eef04bb56314210875a6e7d619692
  ehfetch libcxxabi/src/private_typeinfo.cpp      "$A/private_typeinfo.cpp"      5eb520132ffb270636b8274767d96737a34ea88773c37ffc6bfbf019769d90d0
  # libc++abi private headers (quoted -iquote /work)
  ehfetch libcxxabi/src/cxa_exception.h    "$A/cxa_exception.h"    f6867fd35fc8bafde2f9348a017a2ca9938f577d648d7258d9aef780064ddb52
  ehfetch libcxxabi/src/cxa_handlers.h     "$A/cxa_handlers.h"     2c87e313acb5a9e8a48374cd431da69c98fb2c9ad2c70be82fe7fbed122d00fe
  ehfetch libcxxabi/src/private_typeinfo.h "$A/private_typeinfo.h" 308dd443446dfa0e6972e897f575c4e379f50bbf3aee3f5126f955f44768c803
  ehfetch libcxxabi/src/fallback_malloc.h  "$A/fallback_malloc.h"  a9f725ecf2bfe34f482ead34e182b74013e48fc51902f55eba2a7e30866415b1
  ehfetch libcxxabi/src/abort_message.h    "$A/abort_message.h"    a5d95a89ae7013a171d3f7688f70f7b71e870ff85f2144c250782c399cff20de
  ehfetch libcxxabi/include/cxxabi.h         "$A/cxxabi.h"         3c2ca8786f9419e1151a5fe92b8dbdcdadf0bde3011e7154d60b172b67ff4ebc
  ehfetch libcxxabi/include/__cxxabi_config.h "$A/__cxxabi_config.h" e2e4db49c80aeefef76c1fbd58b2f5e1b4f9fe0f6a215bc75621c768f51dc409
  # libc++ private helpers — the sources include them as "include/<name>" (→ $A/include/)
  ehfetch libcxx/src/include/atomic_support.h "$A/include/atomic_support.h" c01d71b5a8fe48773f3670166030284b1050413e22f24bf21bb8c64637036f9e
  ehfetch libcxx/src/include/refstring.h      "$A/include/refstring.h"      2c9e402b26a5bfe953caf666b5ab098880894dedeb1627062bbe0a94e854027f
  ehfetch libcxx/src/include/aligned_alloc.h  "$A/include/aligned_alloc.h"  c4eefdd38eb927c74c19535f7a80fe7d0097ba99614433fae21c4436484e53e6

  # --- libunwind C source + its headers (pure C → -I/work=$U is fine) ---
  ehfetch libunwind/src/Unwind-wasm.c          "$U/Unwind-wasm.c"         ab81b5759fc30425ec59fa395c90dd04d48eef8b7b1541924d32074d5917130e
  ehfetch libunwind/src/config.h               "$U/config.h"              fd99264860ced6f5b5cd4d5e0ef6eb444a4ab511a47a8b0d91bfab254ab21a1e
  ehfetch libunwind/src/libunwind_ext.h        "$U/libunwind_ext.h"       18f02a65758991c3cd371121861c2a213d6699f929e70104ed791ce32979d945
  ehfetch libunwind/include/__libunwind_config.h "$U/__libunwind_config.h" 9c4d2213e9b6dd77da80d066e7a320ddbf3b62a8e511026e4c7a2e10ec9059f8
  ehfetch libunwind/include/unwind.h           "$U/unwind.h"              e4a58637fc8ca1d29cd600c3c4416aafed50085edf276fa076214c8d81c263f0
  ehfetch libunwind/include/unwind_itanium.h   "$U/unwind_itanium.h"      c8cc61d806e13a2e75e93f1c15afd432f93a99283d27d15f5a28a3ebee989cba
  ehfetch libunwind/include/unwind_arm_ehabi.h "$U/unwind_arm_ehabi.h"    04cf22a069866ae35bf075c36f8d9112700bb9772653d80d9c6c4c856f4e7dbb
  ehfetch libunwind/include/libunwind.h        "$U/libunwind.h"           34d08a481ab71fc699971638cb58693cc9fcc6dafe4680963cb937359cfa6edb

  EHSYS="$ROOT/sysroot"
  # run a clang.wasm subcommand with an ISOLATED /tmp preopen (a shared /tmp races on header probes → flaky
  # "header not found"). $1=workdir mounted /work, rest=argv.
  ehrun() {
    local wd="$1"; shift
    local t; t="$(mktemp -d)"
    wasmtime run -W exceptions=y --dir "$EHSYS::/usr" --dir "$wd::/work" --dir "$t::/tmp" --env TMPDIR=/tmp "$CORE" "$@"
    local rc=$?; rm -rf "$t"; return $rc
  }
  # compile one EH object with retry-on-fail (isolated-tmp flakes). $1=workdir $2=src $3=out $4..=extra flags
  ehobj() {
    local wd="$1" src="$2" out="$3"; shift 3
    local i
    for i in 1 2 3; do
      ehrun "$wd" clang --target=wasm32-wasip1 --sysroot=/usr -O2 "$@" -c "/work/$src" -o "/work/$out" 2>/dev/null || true
      [ -f "$wd/$out" ] && { echo "[clang]   EH obj $out (attempt $i)"; return 0; }
    done
    echo "[clang] EH object build FAILED: $out"; exit 1
  }

  ABIFLAGS="-std=c++14 -fwasm-exceptions -mllvm -wasm-use-legacy-eh=false -iquote /work -DNDEBUG -D_LIBCXXABI_BUILDING_LIBRARY"
  # -fno-rtti objects
  ehobj "$A" cxa_exception_storage.cpp cxa_exception_storage.cpp.obj $ABIFLAGS -fno-rtti
  ehobj "$A" fallback_malloc.cpp        fallback_malloc.cpp.obj        $ABIFLAGS -fno-rtti
  # -frtti objects (cxa_personality + private_typeinfo + cxa_exception)
  ehobj "$A" cxa_exception.cpp   cxa_exception.cpp.obj   $ABIFLAGS -frtti
  ehobj "$A" cxa_personality.cpp cxa_personality.cpp.obj $ABIFLAGS -frtti
  ehobj "$A" private_typeinfo.cpp private_typeinfo.cpp.obj $ABIFLAGS -frtti
  # libunwind C object (-DNDEBUG drops the logAPIs/trace externs)
  ehobj "$U" Unwind-wasm.c Unwind-wasm.c.obj -DNDEBUG -fwasm-exceptions -mllvm -wasm-use-legacy-eh=false \
        -iquote /work -I/work -D_LIBUNWIND_BUILDING_LIBRARY -D_LIBUNWIND_HIDE_SYMBOLS -fms-extensions
  # the __cpp_exception TAG keystone — nothing else defines it
  printf '\t.tagtype\t__cpp_exception i32\n\t.globl\t__cpp_exception\n__cpp_exception:\n' > "$G/tag.s"
  ehobj "$G" tag.s tag.o

  # --- assemble archives (llvm-ar; member paths are /work-relative inside the guest) ---
  ehar() { local t; t="$(mktemp -d)"; wasmtime run --dir "$AR::/work" --dir "$t::/tmp" "$CORE" llvm-ar "$@"; local rc=$?; rm -rf "$t"; return $rc; }
  # libc++abi-eh.a: start from the vendored NO-EH archive, drop the no-EH stubs, add the 5 EH objects
  cp -f "$EHSYS/lib/wasm32-wasip1/libc++abi.a" "$AR/libc++abi-eh.a"
  ehar d /work/libc++abi-eh.a cxa_noexception.cpp.obj cxa_exception_storage.cpp.obj fallback_malloc.cpp.obj private_typeinfo.cpp.obj
  cp -f "$A/cxa_exception.cpp.obj" "$A/cxa_exception_storage.cpp.obj" "$A/fallback_malloc.cpp.obj" "$A/cxa_personality.cpp.obj" "$A/private_typeinfo.cpp.obj" "$AR/"
  ehar rcs /work/libc++abi-eh.a /work/cxa_exception.cpp.obj /work/cxa_exception_storage.cpp.obj /work/fallback_malloc.cpp.obj /work/cxa_personality.cpp.obj /work/private_typeinfo.cpp.obj
  # libunwind-eh.a: the unwind object + the tag keystone
  cp -f "$U/Unwind-wasm.c.obj" "$G/tag.o" "$AR/"
  ehar rcs /work/libunwind-eh.a /work/Unwind-wasm.c.obj /work/tag.o

  [ -f "$AR/libc++abi-eh.a" ] && [ -f "$AR/libunwind-eh.a" ] || { echo "[clang] EH archive assembly FAILED"; exit 1; }
  cp -f "$AR/libc++abi-eh.a" "$AR/libunwind-eh.a" "$EHDIR/"
  rm -rf "$EHTMP"
  echo "[clang] C++ exceptions archives staged → $EHDIR/{libc++abi-eh.a,libunwind-eh.a}"
fi

[ -f "$CORE" ] || { echo "[clang] no llvm.core.wasm after extract"; exit 1; }
[ -d "$ROOT/sysroot/lib" ] || { echo "[clang] no sysroot after extract"; exit 1; }
echo "$CORE" 1>&3
