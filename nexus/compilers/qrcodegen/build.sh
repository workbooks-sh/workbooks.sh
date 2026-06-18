#!/usr/bin/env bash
# Provision the qrcodegen (QR code generation) lane: fetch nayuki's single-file C QR generator (pinned v1.8.0),
# stage src/{qrcodegen.c,qrcodegen.h,driver.c} for build_c_dir. driver encodes a URL -> QR module matrix. Last stdout = src.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; VER="v1.8.0"
exec 3>&1 1>&2
if [ -f "$SRC/qrcodegen.c" ] && [ -f "$SRC/driver.c" ]; then echo "[qr] up to date"; echo "$SRC" 1>&3; exit 0; fi
mkdir -p "$SRC"
curl -fsSL "https://github.com/nayuki/QR-Code-generator/raw/$VER/c/qrcodegen.c" -o "$SRC/qrcodegen.c"
curl -fsSL "https://github.com/nayuki/QR-Code-generator/raw/$VER/c/qrcodegen.h" -o "$SRC/qrcodegen.h"
[ -s "$SRC/qrcodegen.c" ] || { echo "[qr] fetch failed"; exit 1; }
cat > "$SRC/driver.c" <<'C'
#include <stdio.h>
#include "qrcodegen.h"
int main(void){
  uint8_t qr[qrcodegen_BUFFER_LEN_MAX], tmp[qrcodegen_BUFFER_LEN_MAX];
  bool ok = qrcodegen_encodeText("https://workbooks.sh", tmp, qr,
              qrcodegen_Ecc_MEDIUM, qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX, qrcodegen_Mask_AUTO, true);
  if(!ok){ printf("ENCODE_FAIL\n"); return 1; }
  int size = qrcodegen_getSize(qr);
  int dark=0; for(int y=0;y<size;y++) for(int x=0;x<size;x++) if(qrcodegen_getModule(qr,x,y)) dark++;
  printf("qr_ok=%d size=%d dark=%d corner=%d\n", ok, size, dark, qrcodegen_getModule(qr,0,0));
  return 0;
}
C
echo "[qr] staged -> $SRC"; echo "$SRC" 1>&3
