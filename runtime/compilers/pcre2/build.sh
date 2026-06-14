#!/usr/bin/env bash
# Provision the PCRE2 (regex) lane: fetch source, stage the 8-bit library sources (headers + generated
# config.h/pcre2.h/pcre2_chartables.c, lib pcre2_*.c minus the tool/test mains) + driver.c for build_c_dir.
# build_c_dir args: -DPCRE2_CODE_UNIT_WIDTH=8 -DHAVE_CONFIG_H; include_only the 3 #included .c. Last stdout = src.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; VER="10.44"; SHA="86b9cb0aa3bcb7994faa88018292bc704cdbb708e785f7c74352ff6ea7d3175b"
exec 3>&1 1>&2
if [ -f "$SRC/pcre2_compile.c" ] && [ -f "$SRC/driver.c" ]; then echo "[pcre2] up to date"; echo "$SRC" 1>&3; exit 0; fi
TGZ="$SD/pcre2-$VER.tar.gz"
[ -f "$TGZ" ] || { echo "[pcre2] fetch $VER"; curl -fsSL "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$VER/pcre2-$VER.tar.gz" -o "$TGZ"; }
echo "$SHA  $TGZ" | shasum -a 256 -c - || { echo "[pcre2] SHA MISMATCH"; exit 1; }
rm -rf "$SRC" "$SD/pcre2-$VER"; mkdir -p "$SRC"; tar xzf "$TGZ" -C "$SD"
P="$SD/pcre2-$VER/src"
cp "$P"/*.h "$SRC/"
cp "$P/config.h.generic" "$SRC/config.h"; cp "$P/pcre2.h.generic" "$SRC/pcre2.h"; cp "$P/pcre2_chartables.c.dist" "$SRC/pcre2_chartables.c"
cp "$P"/pcre2_*.c "$SRC/"
rm -f "$SRC/pcre2_dftables.c" "$SRC/pcre2grep.c" "$SRC/pcre2test.c" "$SRC/pcre2posix_test.c" "$SRC/pcre2_jit_test.c" "$SRC/pcre2_fuzzsupport.c" "$SRC/pcre2_printint.c" "$SRC/pcre2posix.c" "$SRC/pcre2_chartables.c.dist"
rm -rf "$SD/pcre2-$VER"
cat > "$SRC/driver.c" <<'C'
#include <stdio.h>
#include <string.h>
#define PCRE2_CODE_UNIT_WIDTH 8
#include "pcre2.h"
int main(void){
  int err; PCRE2_SIZE eoff;
  pcre2_code* re = pcre2_compile((PCRE2_SPTR)"(\\\\w+)@(\\\\w+)", PCRE2_ZERO_TERMINATED, 0, &err, &eoff, NULL);
  if(!re){ printf("COMPILE_FAIL\n"); return 1; }
  const char* subj = "hello user@host world";
  pcre2_match_data* md = pcre2_match_data_create_from_pattern(re, NULL);
  int rc = pcre2_match(re, (PCRE2_SPTR)subj, strlen(subj), 0, 0, md, NULL);
  if(rc<1){ printf("NO_MATCH rc=%d\n", rc); return 1; }
  PCRE2_SIZE* ov = pcre2_get_ovector_pointer(md);
  printf("match g1=%.*s g2=%.*s\n", (int)(ov[3]-ov[2]), subj+ov[2], (int)(ov[5]-ov[4]), subj+ov[4]);
  return 0;
}
C
echo "[pcre2] staged $(ls "$SRC"/*.c|wc -l|tr -d ' ') C files -> $SRC"; echo "$SRC" 1>&3
