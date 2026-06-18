#!/usr/bin/env bash
# Provision the zstd lane: fetch zstd source, generate the single-file amalgamation (combine.py), stage
# src/{zstd_single.c, zstd.h, driver.c} for build_c_dir (in-sandbox clang). Idempotent. Last stdout = src dir.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; VER="1.5.6"; SHA="8c29e06cf42aacc1eafc4077ae2ec6c6fcb96a626157e0593d5e82a34fd403c1"
exec 3>&1 1>&2
if [ -f "$SRC/zstd_single.c" ] && [ -f "$SRC/driver.c" ]; then echo "[zstd] up to date"; echo "$SRC" 1>&3; exit 0; fi
TGZ="$SD/zstd-$VER.tar.gz"
[ -f "$TGZ" ] || { echo "[zstd] fetch $VER"; curl -fsSL "https://github.com/facebook/zstd/releases/download/v$VER/zstd-$VER.tar.gz" -o "$TGZ"; }
echo "$SHA  $TGZ" | shasum -a 256 -c - || { echo "[zstd] SHA MISMATCH"; exit 1; }
rm -rf "$SRC" "$SD/zstd-$VER"; mkdir -p "$SRC"; tar xzf "$TGZ" -C "$SD"
( cd "$SD/zstd-$VER/build/single_file_libs" && python3 combine.py -r ../../lib -o "$SRC/zstd_single.c" zstd-in.c >/dev/null )
cp "$SD/zstd-$VER/lib/zstd.h" "$SRC/"; rm -rf "$SD/zstd-$VER"
cat > "$SRC/driver.c" <<'C'
#include <stdio.h>
#include <string.h>
#define ZSTD_STATIC_LINKING_ONLY
#include "zstd.h"
int main(void){
  const char* in = "workbooks forge zstd roundtrip workbooks forge zstd roundtrip workbooks";
  size_t n = strlen(in)+1; char comp[4096], dec[4096];
  size_t c = ZSTD_compress(comp, ZSTD_compressBound(n), in, n, 9);
  if (ZSTD_isError(c)) { printf("COMPRESS_ERR\n"); return 1; }
  size_t d = ZSTD_decompress(dec, sizeof dec, comp, c);
  if (ZSTD_isError(d)) { printf("DECOMPRESS_ERR\n"); return 1; }
  printf("orig=%zu comp=%zu match=%d\n", n, c, strcmp(in, dec)==0);
  return 0;
}
C
echo "[zstd] staged amalgam ($(du -h "$SRC/zstd_single.c"|cut -f1)) + driver -> $SRC"
echo "$SRC" 1>&3
