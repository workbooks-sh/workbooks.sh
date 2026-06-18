#!/usr/bin/env bash
# Provision the stb_image lane: fetch stb_image.h (single-header image decoder: PNG/JPEG/BMP/GIF/...), stage
# src/{stb_image.h, driver.c} for build_c_dir. driver decodes an image from stdin -> dims+pixels. Last stdout = src.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"
exec 3>&1 1>&2
if [ -f "$SRC/stb_image.h" ] && [ -f "$SRC/driver.c" ]; then echo "[stb] up to date"; echo "$SRC" 1>&3; exit 0; fi
mkdir -p "$SRC"
# stb is single-header, no releases; pin a commit for reproducibility.
COMMIT="f0569113c93ad095470c54bf34a17b36646bbbb5"
curl -fsSL "https://raw.githubusercontent.com/nothings/stb/$COMMIT/stb_image.h" -o "$SRC/stb_image.h"
[ -s "$SRC/stb_image.h" ] || { echo "[stb] fetch failed"; exit 1; }
cat > "$SRC/driver.c" <<'C'
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#include <stdio.h>
#include <stdlib.h>
int main(void){
  unsigned char* buf = malloc(1<<20); size_t n=0,r;
  while((r=fread(buf+n,1,4096,stdin))>0) n+=r;
  int w,h,c;
  unsigned char* px = stbi_load_from_memory(buf,(int)n,&w,&h,&c,0);
  if(!px){ printf("DECODE_FAIL: %s\n", stbi_failure_reason()); return 1; }
  printf("w=%d h=%d ch=%d r0=%d g0=%d b0=%d\n", w,h,c, px[0],px[1],px[2]);
  return 0;
}
C
echo "[stb] staged stb_image.h + driver -> $SRC"; echo "$SRC" 1>&3
