#!/usr/bin/env bash
# Provision the utf8proc (Unicode normalization) lane: fetch source, stage src/{utf8proc.c,utf8proc.h,
# utf8proc_data.c,driver.c} for build_c_dir (utf8proc_data.c is #included by utf8proc.c -> include_only). Last stdout = src.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; VER="2.9.0"; SHA="18c1626e9fc5a2e192311e36b3010bfc698078f692888940f1fa150547abb0c1"
exec 3>&1 1>&2
if [ -f "$SRC/utf8proc.c" ] && [ -f "$SRC/driver.c" ]; then echo "[utf8proc] up to date"; echo "$SRC" 1>&3; exit 0; fi
TGZ="$SD/utf8proc-$VER.tar.gz"
[ -f "$TGZ" ] || { echo "[utf8proc] fetch $VER"; curl -fsSL "https://github.com/JuliaStrings/utf8proc/archive/refs/tags/v$VER.tar.gz" -o "$TGZ"; }
echo "$SHA  $TGZ" | shasum -a 256 -c - || { echo "[utf8proc] SHA MISMATCH"; exit 1; }
rm -rf "$SRC" "$SD/utf8proc-$VER"; mkdir -p "$SRC"; tar xzf "$TGZ" -C "$SD"
cp "$SD/utf8proc-$VER/"{utf8proc.c,utf8proc.h,utf8proc_data.c} "$SRC/"; rm -rf "$SD/utf8proc-$VER"
cat > "$SRC/driver.c" <<'C'
#include <stdio.h>
#include "utf8proc.h"
int main(void){
  utf8proc_uint8_t* out;
  utf8proc_ssize_t n = utf8proc_map((const utf8proc_uint8_t*)"HeLLo", 5, &out, UTF8PROC_CASEFOLD | UTF8PROC_STABLE);
  printf("casefold=%.*s\n", (int)n, out);
  const char* combo = "e\xCC\x81";
  utf8proc_uint8_t* nfc;
  utf8proc_ssize_t m = utf8proc_map((const utf8proc_uint8_t*)combo, 3, &nfc, UTF8PROC_COMPOSE | UTF8PROC_STABLE);
  printf("nfc_bytes="); for(int i=0;i<m;i++) printf("%02x", nfc[i]); printf("\n");
  return 0;
}
C
echo "[utf8proc] staged -> $SRC"; echo "$SRC" 1>&3
