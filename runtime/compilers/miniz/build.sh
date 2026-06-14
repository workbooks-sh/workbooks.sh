#!/usr/bin/env bash
# Provision the miniz (zlib/gzip/ZIP) lane: fetch the amalgamated release, stage src/{miniz.c,miniz.h,driver.c}
# for build_c_dir. driver = create a ZIP in memory + read back + extract. Last stdout = src dir.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; VER="3.0.2"; SHA="ada38db0b703a56d3dd6d57bf84a9c5d664921d870d8fea4db153979fb5332c5"
exec 3>&1 1>&2
if [ -f "$SRC/miniz.c" ] && [ -f "$SRC/driver.c" ]; then echo "[miniz] up to date"; echo "$SRC" 1>&3; exit 0; fi
ZIP="$SD/miniz-$VER.zip"
[ -f "$ZIP" ] || { echo "[miniz] fetch $VER"; curl -fsSL "https://github.com/richgel999/miniz/releases/download/$VER/miniz-$VER.zip" -o "$ZIP"; }
echo "$SHA  $ZIP" | shasum -a 256 -c - || { echo "[miniz] SHA MISMATCH"; exit 1; }
rm -rf "$SRC" "$SD/.mztmp"; mkdir -p "$SRC" "$SD/.mztmp"; unzip -o -q "$ZIP" -d "$SD/.mztmp"
find "$SD/.mztmp" -name miniz.c -exec cp {} "$SRC/" \; ; find "$SD/.mztmp" -name miniz.h -exec cp {} "$SRC/" \;
rm -rf "$SD/.mztmp"
cat > "$SRC/driver.c" <<'C'
#include <stdio.h>
#include <string.h>
#include "miniz.h"
int main(void){
  const char* data="workbooks forge miniz zip archive roundtrip payload";
  size_t len=strlen(data);
  mz_zip_archive zw; memset(&zw,0,sizeof zw); mz_zip_writer_init_heap(&zw,0,0);
  mz_zip_writer_add_mem(&zw,"hello.txt",data,len,MZ_BEST_COMPRESSION);
  void* buf=0; size_t sz=0; mz_zip_writer_finalize_heap_archive(&zw,&buf,&sz); mz_zip_writer_end(&zw);
  mz_zip_archive zr; memset(&zr,0,sizeof zr); mz_zip_reader_init_mem(&zr,buf,sz,0);
  int nfiles=(int)mz_zip_reader_get_num_files(&zr);
  size_t osz=0; void* out=mz_zip_reader_extract_file_to_heap(&zr,"hello.txt",&osz,0);
  int match = out && osz==len && memcmp(out,data,len)==0;
  printf("zip_bytes=%zu files=%d extract_match=%d\n",sz,nfiles,match);
  mz_zip_reader_end(&zr); return 0;
}
C
echo "[miniz] staged -> $SRC"; echo "$SRC" 1>&3
