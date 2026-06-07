#!/usr/bin/env bash
# Build mrustc (Rust→C compiler) to wasm32-wasip1 so it runs IN the sandbox. Its C output
# is then compiled to wasm by the clang lane (compilers/clang/), mirroring the Zig chain.
#
# STATUS: IN-PROGRESS PORT (wb-zyl.7) — see PORT-LOG.org. Validated so far: tools/common
# compiles to wasm with wasi-sdk-33 (fstream/exceptions) + the serial-jobserver patch. The
# core src/ compile + link + the deeper walls (32-bit, memory, syscalls) are the grind.
#
# Contract (build_and_register_script): last stdout line = the wasm path; progress → stderr.
# NOTE: this recipe is allowed to FAIL while the port is in progress — the grind loop fixes
# the next wall and updates this script + PORT-LOG. It is NOT a stub: every line is real.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SD/mrustc-root"
SRC="$ROOT/mrustc"
WASM="$ROOT/mrustc.wasm"

MRUSTC_REF=be69c7479a10bdce1b86cb886789d14a143ddf34
WASI_SDK_VER=33.0
# wasi-sdk-33 per-platform sha256 (arm64-macos, x86_64-linux)
WASI_SHA_ARM64_MACOS=85c997a2665ead91673b5bb88b7d0df3fc8900df3bfa244f720d478187bbdc78
WASI_SHA_X86_64_LINUX=0ba8b5bfaeb2adf3f29bab5841d76cf5318ab8e1642ea195f88baba1abd47bce

exec 3>&1 1>&2   # progress → stderr; fd 3 = the one stdout line (the wasm path)

mkdir -p "$ROOT"

# --- 1. wasi-sdk (native clang + wasi sysroot with fstream + exceptions) ---
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  WA=wasi-sdk-${WASI_SDK_VER}-arm64-macos;  WSHA=$WASI_SHA_ARM64_MACOS ;;
  Linux-x86_64)  WA=wasi-sdk-${WASI_SDK_VER}-x86_64-linux; WSHA=$WASI_SHA_X86_64_LINUX ;;
  *) echo "[rust] add wasi-sdk sha for $(uname -s)-$(uname -m) to build.sh"; exit 1 ;;
esac
SDK="$ROOT/$WA"
if [ ! -x "$SDK/bin/clang++" ]; then
  TARB="$ROOT/$WA.tar.gz"
  [ -f "$TARB" ] || { echo "[rust] fetching $WA"; curl -fsSL -o "$TARB" \
    "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VER%.*}/$WA.tar.gz"; }
  echo "$WSHA  $TARB" | shasum -a 256 -c - || { echo "[rust] wasi-sdk SHA MISMATCH"; exit 1; }
  tar -xzf "$TARB" -C "$ROOT"
fi
CXX="$SDK/bin/clang++"

# --- 2. mrustc source (pinned) ---
if [ ! -d "$SRC" ]; then
  echo "[rust] cloning mrustc @ $MRUSTC_REF"
  git clone --filter=blob:none "https://github.com/thepowersgang/mrustc" "$SRC"
  git -C "$SRC" checkout -q "$MRUSTC_REF"
fi

# --- 3. WASI patches (idempotent) ---
# 3a. jobserver: no pipe/fork on WASI -> serial.
JS="$SRC/tools/common/jobserver.cpp"
if ! grep -q "__wasi__" "$JS"; then
  python3 - "$JS" <<'PY'
import sys
f=sys.argv[1]; s=open(f).read(); a='#include "jobserver.h"'
s=s.replace(a, a+'''
#if defined(__wasi__)
#include <memory>
namespace { class JobServer_Serial: public JobServer {
public: bool take_one(unsigned long) override { return true; } void return_one() override {} }; }
::std::unique_ptr<JobServer> JobServer::create(size_t) { return ::std::unique_ptr<JobServer>(new JobServer_Serial()); }
#else
''',1)
open(f,"w").write(s.rstrip()+"\n#endif // !__wasi__\n")
PY
  echo "[rust] patched jobserver.cpp (wasi serial)"
fi
# 3b. codegen_c: mrustc shells out to the C compiler via system() (impossible on WASI).
#     Skip it under __wasi__ — mrustc emits the .c; the clang lane compiles it separately.
CG="$SRC/src/trans/codegen_c.cpp"
if ! grep -q "__wasi__" "$CG"; then
  perl -0pi -e 's/(int ec = )(system\(cmd_ss\.str\(\)\.c_str\(\)\);)/\1\n#if defined(__wasi__)\n            0; \/\/ WASI: emit C only; the clang lane links it (no subprocess in-sandbox)\n#else\n            \2\n#endif/g' "$CG"
  echo "[rust] patched codegen_c.cpp (wasi: emit C, skip system() compile)"
fi

# --- 4. compile all sources to wasm32-wasip1, link to mrustc.wasm ---
# tools/common is VALIDATED. The src/ core compile is the active grind (PORT-LOG).
OBJ="$ROOT/obj"; mkdir -p "$OBJ"
CXXFLAGS=(--target=wasm32-wasip1 -fwasm-exceptions -fno-rtti -O2 -std=c++14
          -I "$SRC/src" -I "$SRC/tools/common" -D_WASI_EMULATED_PROCESS_CLOCKS)
mapfile -t SRCS < <(find "$SRC/src" "$SRC/tools/common" -name '*.cpp' | sort)
echo "[rust] compiling ${#SRCS[@]} sources to wasm..."
OBJS=()
for f in "${SRCS[@]}"; do
  o="$OBJ/$(echo "$f" | tr '/.' '__').o"
  "$CXX" "${CXXFLAGS[@]}" -c "$f" -o "$o"
  OBJS+=("$o")
done
echo "[rust] linking mrustc.wasm"
"$CXX" --target=wasm32-wasip1 -fwasm-exceptions "${OBJS[@]}" -o "$WASM"

[ -f "$WASM" ] || { echo "[rust] no mrustc.wasm after link"; exit 1; }
echo "$WASM" 1>&3
