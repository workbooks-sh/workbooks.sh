#!/usr/bin/env bash
# Build a single-file Lua 5.4 interpreter (stdlib compiled in) for wasm32-wasi
# using wasi-sdk (its sysroot ships the sjlj-enabled libc; Lua needs setjmp/longjmp
# for error handling). Run on wasmtime with -W exceptions=y. No upstream prebuilt
# exists, so we build from a pinned source tarball. Prints the output wasm path as
# the LAST stdout line; all build noise goes to stderr.
set -euo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec 3>&1 1>&2                      # stdout→fd3 (result only); chatter→stderr

WORK="${TMPDIR:-/tmp}/wb-lua-build"; mkdir -p "$WORK"; cd "$WORK"

# --- wasi-sdk (env override, else fetch pinned wasi-sdk-33 for this OS/arch) ---
if [ -n "${WB_WASI_SDK:-}" ] && [ -x "$WB_WASI_SDK/bin/clang" ]; then
  SDK="$WB_WASI_SDK"
else
  case "$(uname -s)" in Darwin) o=macos;; Linux) o=linux;; *) echo "unsupported OS"; exit 1;; esac
  case "$(uname -m)" in arm64|aarch64) a=arm64;; x86_64) a=x86_64;; *) echo "unsupported arch"; exit 1;; esac
  asset="wasi-sdk-33.0-${a}-${o}"
  [ -x "$WORK/$asset/bin/clang" ] || curl -fsSL "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-33/${asset}.tar.gz" | tar xz
  SDK="$WORK/$asset"
fi
CLANG="$SDK/bin/clang"

# --- Lua source (pinned + sha-verified) ---
LUA=lua-5.4.7
SHA=9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30
if [ ! -d "$LUA" ]; then
  curl -fsSL "https://www.lua.org/ftp/${LUA}.tar.gz" -o lua.tgz
  echo "${SHA}  lua.tgz" | shasum -a 256 -c - || { echo "lua source sha mismatch"; exit 1; }
  tar xzf lua.tgz
fi

# --- compile single-file lua.wasm (sjlj for longjmp; tmpnam/clock/system stubbed) ---
cd "$LUA/src"
SRCS=$(ls *.c | grep -v '^luac.c$')
"$CLANG" -O2 -D_WASI_EMULATED_SIGNAL -DLUA_TMPNAMBUFSIZE=32 '-Dlua_tmpnam(b,e)=((void)(b),(e)=1)' \
  -mllvm -wasm-enable-sjlj -mllvm -wasm-use-legacy-eh=false \
  -o "$WORK/lua.wasm" $SRCS "$SD/shim.c" -lsetjmp -lwasi-emulated-signal -lm

echo "$WORK/lua.wasm" >&3            # the ONLY stdout line: the artifact path
