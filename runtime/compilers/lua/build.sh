#!/usr/bin/env bash
# Provision the Lua lane source: fetch the canonical Lua C source (lua.org), stage src/ for build_c_dir
# (the in-sandbox clang lane compiles it to wasm). Drops luac.c (the separate bytecode-compiler main) so
# only lua.c's main() is the entry. Idempotent. Last stdout line = the staged src dir.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; VER="5.4.7"
SHA="9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30"
exec 3>&1 1>&2
if [ -d "$SRC" ] && [ -f "$SRC/lua.c" ]; then echo "[lua] up to date"; echo "$SRC" 1>&3; exit 0; fi
TGZ="$SD/lua-$VER.tar.gz"
[ -f "$TGZ" ] || { echo "[lua] fetch lua-$VER"; curl -fsSL "https://www.lua.org/ftp/lua-$VER.tar.gz" -o "$TGZ"; }
echo "$SHA  $TGZ" | shasum -a 256 -c - || { echo "[lua] SHA MISMATCH"; exit 1; }
rm -rf "$SRC"; mkdir -p "$SRC"
tar xzf "$TGZ" -C "$SD"
cp "$SD/lua-$VER/src/"*.c "$SD/lua-$VER/src/"*.h "$SRC/"
rm -f "$SRC/luac.c"   # keep lua.c's main(), drop the compiler binary
rm -rf "$SD/lua-$VER"
echo "[lua] staged $(ls "$SRC"/*.c | wc -l | tr -d ' ') C files -> $SRC"
echo "$SRC" 1>&3
