#!/usr/bin/env bash
# Provision the stb_image_write lane: fetch stb_image_write.h (PNG/JPG/BMP/TGA encoder) + stb_image.h (for the
# roundtrip), stage src/{*.h, driver.c} for build_c_dir. driver encodes pixels -> PNG -> decodes back. Last stdout = src.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; COMMIT="f0569113c93ad095470c54bf34a17b36646bbbb5"
exec 3>&1 1>&2
if [ -f "$SRC/stb_image_write.h" ] && [ -f "$SRC/driver.c" ]; then echo "[stbwrite] up to date"; echo "$SRC" 1>&3; exit 0; fi
mkdir -p "$SRC"
curl -fsSL "https://raw.githubusercontent.com/nothings/stb/$COMMIT/stb_image_write.h" -o "$SRC/stb_image_write.h"
curl -fsSL "https://raw.githubusercontent.com/nothings/stb/$COMMIT/stb_image.h" -o "$SRC/stb_image.h"
[ -s "$SRC/stb_image_write.h" ] || { echo "[stbwrite] fetch failed"; exit 1; }
cat > "$SRC/driver.c" <<'C'
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#include <stdio.h>
#include <stdlib.h>
int main(void){
  unsigned char px[2*2*4];
  for(int i=0;i<4;i++){ px[i*4]=255; px[i*4+1]=128; px[i*4+2]=0; px[i*4+3]=255; }
  int len=0; unsigned char* png = stbi_write_png_to_mem(px, 2*4, 2, 2, 4, &len);
  if(!png){ printf("ENCODE_FAIL\n"); return 1; }
  int w,h,c; unsigned char* dec = stbi_load_from_memory(png, len, &w,&h,&c, 0);
  if(!dec){ printf("DECODE_FAIL\n"); return 1; }
  printf("png_len=%d w=%d h=%d ch=%d r=%d g=%d b=%d\n", len, w,h,c, dec[0],dec[1],dec[2]);
  return 0;
}
C
echo "[stbwrite] staged -> $SRC"; echo "$SRC" 1>&3
