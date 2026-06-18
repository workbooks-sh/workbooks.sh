#!/usr/bin/env bash
# Provision the md4c (Markdown -> HTML) lane: fetch source, stage src/{md4c.c,md4c.h,md4c-html.c,md4c-html.h,
# entity.c,entity.h,driver.c} for build_c_dir. driver renders CommonMark to HTML. Last stdout = src dir.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; VER="0.5.2"; SHA="55d0111d48fb11883aaee91465e642b8b640775a4d6993c2d0e7a8092758ef21"
exec 3>&1 1>&2
if [ -f "$SRC/md4c.c" ] && [ -f "$SRC/driver.c" ]; then echo "[md4c] up to date"; echo "$SRC" 1>&3; exit 0; fi
TGZ="$SD/md4c-$VER.tar.gz"
[ -f "$TGZ" ] || { echo "[md4c] fetch $VER"; curl -fsSL "https://github.com/mity/md4c/archive/refs/tags/release-$VER.tar.gz" -o "$TGZ"; }
echo "$SHA  $TGZ" | shasum -a 256 -c - || { echo "[md4c] SHA MISMATCH"; exit 1; }
rm -rf "$SRC" "$SD/md4c-release-$VER"; mkdir -p "$SRC"; tar xzf "$TGZ" -C "$SD"
cp "$SD/md4c-release-$VER/src/"{md4c.c,md4c.h,md4c-html.c,md4c-html.h,entity.c,entity.h} "$SRC/"; rm -rf "$SD/md4c-release-$VER"
cat > "$SRC/driver.c" <<'C'
#include <stdio.h>
#include <string.h>
#include "md4c-html.h"
static char out[8192]; static int olen=0;
static void cb(const MD_CHAR* d, MD_SIZE n, void* u){ (void)u; memcpy(out+olen, d, n); olen+=(int)n; out[olen]=0; }
int main(void){
  const char* md = "# Hello\n\nThis is **bold** and *em* with [link](http://x).\n";
  md_html(md, (MD_SIZE)strlen(md), cb, NULL, 0, 0);
  printf("%s", out);
  return 0;
}
C
echo "[md4c] staged -> $SRC"; echo "$SRC" 1>&3
