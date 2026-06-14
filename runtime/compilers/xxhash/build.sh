#!/usr/bin/env bash
# Provision the xxHash (fast non-crypto hashing) lane: fetch the single-header xxhash.h (pinned v0.8.2), stage
# src/{xxhash.h, driver.c} for build_c_dir. driver computes XXH32/64/XXH3 of a buffer. Last stdout = src dir.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; VER="v0.8.2"
exec 3>&1 1>&2
if [ -f "$SRC/xxhash.h" ] && [ -f "$SRC/driver.c" ]; then echo "[xxhash] up to date"; echo "$SRC" 1>&3; exit 0; fi
mkdir -p "$SRC"
curl -fsSL "https://github.com/Cyan4973/xxHash/raw/$VER/xxhash.h" -o "$SRC/xxhash.h"
[ -s "$SRC/xxhash.h" ] || { echo "[xxhash] fetch failed"; exit 1; }
cat > "$SRC/driver.c" <<'C'
#define XXH_IMPLEMENTATION
#define XXH_STATIC_LINKING_ONLY
#include "xxhash.h"
#include <stdio.h>
#include <string.h>
int main(void){
  const char* data = "workbooks forge xxhash";
  size_t n = strlen(data);
  unsigned long long h64 = (unsigned long long)XXH64(data, n, 0);
  unsigned h32 = (unsigned)XXH32(data, n, 0);
  unsigned long long h3  = (unsigned long long)XXH3_64bits(data, n);
  printf("xxh64=%016llx xxh32=%08x xxh3=%016llx\n", h64, h32, h3);
  return 0;
}
C
echo "[xxhash] staged -> $SRC"; echo "$SRC" 1>&3
