#!/usr/bin/env bash
# Provision the libexpat (XML parser) lane: fetch source, stage lib .c/.h + a minimal expat_config.h
# (XML_POOR_ENTROPY avoids getrandom/arc4random absent on wasi) + driver.c for build_c_dir. Last stdout = src.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; VER="2.6.4"; SHA="fd03b7172b3bd7427a3e7a812063f74754f24542429b634e0db6511b53fb2278"
exec 3>&1 1>&2
if [ -f "$SRC/xmlparse.c" ] && [ -f "$SRC/driver.c" ]; then echo "[expat] up to date"; echo "$SRC" 1>&3; exit 0; fi
TGZ="$SD/expat-$VER.tar.gz"
[ -f "$TGZ" ] || { echo "[expat] fetch $VER"; curl -fsSL "https://github.com/libexpat/libexpat/releases/download/R_${VER//./_}/expat-$VER.tar.gz" -o "$TGZ"; }
echo "$SHA  $TGZ" | shasum -a 256 -c - || { echo "[expat] SHA MISMATCH"; exit 1; }
rm -rf "$SRC" "$SD/expat-$VER"; mkdir -p "$SRC"; tar xzf "$TGZ" -C "$SD"
cp "$SD/expat-$VER/lib/"*.c "$SD/expat-$VER/lib/"*.h "$SRC/"; rm -rf "$SD/expat-$VER"
cat > "$SRC/expat_config.h" <<'H'
#define BYTEORDER 1234
#define HAVE_MEMMOVE 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define XML_CONTEXT_BYTES 1024
#define XML_DTD 1
#define XML_GE 1
#define XML_NS 1
#define XML_POOR_ENTROPY 1
H
cat > "$SRC/driver.c" <<'C'
#include <stdio.h>
#include <string.h>
#include "expat.h"
static int items=0; static char buf[256]; static int cap=0;
static void start(void* u, const XML_Char* name, const XML_Char** at){ (void)u;(void)at; if(strcmp(name,"item")==0){ items++; cap=1; buf[0]=0; } }
static void chars(void* u, const XML_Char* s, int len){ (void)u; if(cap){ int n=len<200?len:200; memcpy(buf+strlen(buf), s, n); buf[strlen(buf)]=0; } }
static void endel(void* u, const XML_Char* name){ (void)u; if(strcmp(name,"item")==0) cap=0; }
int main(void){
  const char* xml="<root><item id='1'>hello</item><item id='2'>world</item></root>";
  XML_Parser p=XML_ParserCreate(NULL);
  XML_SetElementHandler(p,start,endel); XML_SetCharacterDataHandler(p,chars);
  int ok=XML_Parse(p, xml, strlen(xml), 1);
  printf("parse_ok=%d items=%d lasttext=%s\n", ok==XML_STATUS_OK, items, buf);
  XML_ParserFree(p); return 0;
}
C
echo "[expat] staged -> $SRC"; echo "$SRC" 1>&3
