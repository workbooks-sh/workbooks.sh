#!/usr/bin/env bash
# Build mrustc (a C++ Rust→C compiler, bootstraps Rust 1.90) to wasm32-wasip1 so it runs
# IN the sandbox. Its C output is then compiled to wasm by the clang lane — mirroring the
# Zig chain. VALIDATED: mrustc.wasm builds, runs under wasmtime, parses Rust, loads target.
# REMAINING (grind): provide the Rust stdlib so a real .rs compiles end-to-end (PORT-LOG).
#
# Contract (build_and_register_script): last stdout line = the wasm path; progress → stderr.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SD/mrustc-root"
SRC="$ROOT/mrustc"
ZLIB="$ROOT/zlib"
WASM="$ROOT/mrustc.wasm"

MRUSTC_REF=be69c7479a10bdce1b86cb886789d14a143ddf34
ZLIB_REF=v1.3.1
WASI_SDK_VER=33.0
WASI_SHA_ARM64_MACOS=85c997a2665ead91673b5bb88b7d0df3fc8900df3bfa244f720d478187bbdc78
WASI_SHA_X86_64_LINUX=0ba8b5bfaeb2adf3f29bab5841d76cf5318ab8e1642ea195f88baba1abd47bce

exec 3>&1 1>&2   # progress → stderr; fd 3 = the one stdout line (the wasm path)
mkdir -p "$ROOT"

# --- wasi-sdk (native clang targeting wasm32-wasi; libc++ with <fstream> + EH multilib) ---
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) WA=wasi-sdk-${WASI_SDK_VER}-arm64-macos;  WSHA=$WASI_SHA_ARM64_MACOS ;;
  Linux-x86_64) WA=wasi-sdk-${WASI_SDK_VER}-x86_64-linux; WSHA=$WASI_SHA_X86_64_LINUX ;;
  *) echo "[rust] add wasi-sdk sha for $(uname -s)-$(uname -m)"; exit 1 ;;
esac
SDK="$ROOT/$WA"
if [ ! -x "$SDK/bin/clang++" ]; then
  TARB="$ROOT/$WA.tar.gz"
  [ -f "$TARB" ] || { echo "[rust] fetching $WA"; curl -fsSL -o "$TARB" \
    "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VER%.*}/$WA.tar.gz"; }
  echo "$WSHA  $TARB" | shasum -a 256 -c - || { echo "[rust] wasi-sdk SHA MISMATCH"; exit 1; }
  tar -xzf "$TARB" -C "$ROOT"
fi
CXX="$SDK/bin/clang++"; CC="$SDK/bin/clang"

# --- sources (pinned) ---
[ -d "$SRC" ]  || { echo "[rust] clone mrustc"; git clone --filter=blob:none https://github.com/thepowersgang/mrustc "$SRC"; git -C "$SRC" checkout -q "$MRUSTC_REF"; }
[ -d "$ZLIB" ] || { echo "[rust] clone zlib";   git clone --depth 1 -b "$ZLIB_REF" https://github.com/madler/zlib "$ZLIB"; }

# --- WASI patches (idempotent) — no fork/pipe/spawn/system in the sandbox ---
JS="$SRC/tools/common/jobserver.cpp"
grep -q __wasi__ "$JS" || python3 - "$JS" <<'PY'
import sys; f=sys.argv[1]; s=open(f).read(); a='#include "jobserver.h"'
s=s.replace(a,a+'\n#if defined(__wasi__)\n#include <memory>\nnamespace { class JobServer_Serial: public JobServer {\npublic: bool take_one(unsigned long) override { return true; } void return_one() override {} }; }\n::std::unique_ptr<JobServer> JobServer::create(size_t) { return ::std::unique_ptr<JobServer>(new JobServer_Serial()); }\n#else\n',1)
open(f,"w").write(s.rstrip()+"\n#endif // !__wasi__\n")
PY
CG="$SRC/src/trans/codegen_c.cpp"
grep -q __wasi__ "$CG" || perl -0pi -e 's/(int ec = )(system\(cmd_ss\.str\(\)\.c_str\(\)\);)/\1\n#if defined(__wasi__)\n            0;\n#else\n            \2\n#endif/g' "$CG"
PM="$SRC/src/expand/proc_macro.cpp"
grep -q __wasi__ "$PM" || perl -0pi -e 's{# include <spawn.h>\n# include <sys/wait.h>}{#if !defined(__wasi__)\n# include <spawn.h>\n# include <sys/wait.h>\n#endif}' "$PM"

# --- version defines header ---
cat > "$ROOT/ver.h" <<EOF
#define VERSION_GIT_ISDIRTY 0
#define VERSION_GIT_FULLHASH "$MRUSTC_REF"
#define VERSION_GIT_SHORTHASH "${MRUSTC_REF:0:8}"
#define VERSION_GIT_BRANCH "wasm"
#define VERSION_BUILDTIME "unknown"
EOF

# --- zlib → wasm (mrustc compresses serialized HIR; mandatory) ---
ZOBJ="$ROOT/zobj"; mkdir -p "$ZOBJ"
for c in adler32 crc32 deflate inflate inftrees inffast trees zutil compress uncompr gzclose gzlib gzread gzwrite; do
  [ -f "$ZLIB/$c.c" ] && "$CC" --target=wasm32-wasip1 -O2 -DZ_HAVE_UNISTD_H -c "$ZLIB/$c.c" -o "$ZOBJ/$c.o"
done

# --- compile mrustc → wasm (NEW exnref EH so wasmtime -W exceptions=y accepts it; the
#     wasi-sdk default emits legacy try/catch which wasmtime 45 rejects) ---
OBJ="$ROOT/obj"; mkdir -p "$OBJ"
NEWEH="-mllvm -wasm-use-legacy-eh=false"
FLAGS=(--target=wasm32-wasip1 -fwasm-exceptions $NEWEH -O1 -std=c++14
       -include "$SD/wasi/wasi_compat.h" -I"$ZLIB" -I"$SRC/src/include" -I"$SRC/src" -I"$SRC/tools/common"
       -D_WASI_EMULATED_PROCESS_CLOCKS)
echo "[rust] compiling mrustc sources to wasm (~130 TUs)..."
OBJS=()
while IFS= read -r f; do
  o="$OBJ/$(echo "$f" | tr '/.' '__').o"
  inc=(); [ "$(basename "$f")" = version.cpp ] && inc=(-include "$ROOT/ver.h")
  "$CXX" "${FLAGS[@]}" ${inc[@]+"${inc[@]}"} -c "$f" -o "$o"
  OBJS+=("$o")
done < <(find "$SRC/src" "$SRC/tools/common" -name '*.cpp' | sort)
# system() stub (no subprocess in-sandbox)
"$CXX" "${FLAGS[@]}" -c "$SD/wasi/sys_stub.cpp" -o "$OBJ/zz_sys_stub.o"; OBJS+=("$OBJ/zz_sys_stub.o")

echo "[rust] linking mrustc.wasm"
"$CXX" --target=wasm32-wasip1 -fwasm-exceptions $NEWEH "${OBJS[@]}" "$ZOBJ"/*.o \
  -lwasi-emulated-process-clocks -lunwind -o "$WASM"

[ -f "$WASM" ] || { echo "[rust] no mrustc.wasm after link"; exit 1; }
echo "$WASM" 1>&3
