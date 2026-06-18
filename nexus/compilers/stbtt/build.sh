#!/usr/bin/env bash
# Provision the stb_truetype (font rasterization) lane: fetch stb_truetype.h + a small open TTF (Tiny5), stage
# src/{stb_truetype.h, font.ttf, driver.c} for build_c_dir. driver reads the font from STDIN and rasterizes a
# glyph to a bitmap. Last stdout = src dir.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; STBC="f0569113c93ad095470c54bf34a17b36646bbbb5"; FSHA="cb8168f80cfee2f47f6db59f2a7afbde31cdcdcdcf262e7a993e4d468a5bf4b0"
exec 3>&1 1>&2
if [ -f "$SRC/stb_truetype.h" ] && [ -f "$SRC/driver.c" ]; then echo "[stbtt] up to date"; echo "$SRC" 1>&3; exit 0; fi
mkdir -p "$SRC"
curl -fsSL "https://raw.githubusercontent.com/nothings/stb/$STBC/stb_truetype.h" -o "$SRC/stb_truetype.h"
curl -fsSL "https://github.com/google/fonts/raw/main/ofl/tiny5/Tiny5-Regular.ttf" -o "$SRC/font.ttf"
echo "$FSHA  $SRC/font.ttf" | shasum -a 256 -c - || { echo "[stbtt] font SHA MISMATCH"; exit 1; }
cat > "$SRC/driver.c" <<'C'
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
#include <stdio.h>
#include <stdlib.h>
int main(void){
  unsigned char* buf = malloc(1<<20); size_t n=0,r;
  while((r=fread(buf+n,1,4096,stdin))>0) n+=r;
  stbtt_fontinfo font;
  if(!stbtt_InitFont(&font, buf, stbtt_GetFontOffsetForIndex(buf,0))){ printf("INIT_FAIL\n"); return 1; }
  int w,h,xoff,yoff;
  unsigned char* bmp = stbtt_GetCodepointBitmap(&font, 0, stbtt_ScaleForPixelHeight(&font, 24), 'A', &w,&h,&xoff,&yoff);
  if(!bmp){ printf("RASTER_FAIL\n"); return 1; }
  int ink=0; for(int i=0;i<w*h;i++) if(bmp[i]>0) ink++;
  printf("glyph_A w=%d h=%d ink_pixels=%d\n", w, h, ink);
  return 0;
}
C
echo "[stbtt] staged -> $SRC"; echo "$SRC" 1>&3
