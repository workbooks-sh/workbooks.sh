#!/usr/bin/env bash
# Provision the gumbo (HTML5 parser) lane: fetch source, stage src/{*.c,*.h,driver.c} for build_c_dir.
# driver parses HTML -> DOM -> extracts <h1>/<p> text. Idempotent. Last stdout = src dir.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; VER="0.10.1"; SHA="28463053d44a5dfbc4b77bcf49c8cee119338ffa636cc17fc3378421d714efad"
exec 3>&1 1>&2
if [ -f "$SRC/parser.c" ] && [ -f "$SRC/driver.c" ]; then echo "[gumbo] up to date"; echo "$SRC" 1>&3; exit 0; fi
TGZ="$SD/gumbo-$VER.tar.gz"
[ -f "$TGZ" ] || { echo "[gumbo] fetch $VER"; curl -fsSL "https://github.com/google/gumbo-parser/archive/refs/tags/v$VER.tar.gz" -o "$TGZ"; }
echo "$SHA  $TGZ" | shasum -a 256 -c - || { echo "[gumbo] SHA MISMATCH"; exit 1; }
rm -rf "$SRC" "$SD/gumbo-parser-$VER"; mkdir -p "$SRC"; tar xzf "$TGZ" -C "$SD"
cp "$SD/gumbo-parser-$VER/src/"*.c "$SD/gumbo-parser-$VER/src/"*.h "$SRC/"; rm -rf "$SD/gumbo-parser-$VER"
cat > "$SRC/driver.c" <<'C'
#include <stdio.h>
#include "gumbo.h"
static const char* find_tag_text(GumboNode* n, GumboTag tag){
  if(n->type != GUMBO_NODE_ELEMENT) return 0;
  if(n->v.element.tag == tag){
    GumboVector* ch=&n->v.element.children;
    for(unsigned i=0;i<ch->length;i++){ GumboNode* c=ch->data[i]; if(c->type==GUMBO_NODE_TEXT) return c->v.text.text; }
  }
  GumboVector* ch=&n->v.element.children;
  for(unsigned i=0;i<ch->length;i++){ const char* r=find_tag_text((GumboNode*)ch->data[i],tag); if(r) return r; }
  return 0;
}
int main(void){
  const char* html="<html><head><title>T</title></head><body><h1>Hello Forge</h1><p>world</p></body></html>";
  GumboOutput* o=gumbo_parse(html);
  const char* h1=find_tag_text(o->root, GUMBO_TAG_H1);
  const char* p =find_tag_text(o->root, GUMBO_TAG_P);
  printf("h1=%s p=%s\n", h1?h1:"(none)", p?p:"(none)");
  gumbo_destroy_output(&kGumboDefaultOptions, o);
  return 0;
}
C
echo "[gumbo] staged $(ls "$SRC"/*.c|wc -l|tr -d ' ') C files -> $SRC"; echo "$SRC" 1>&3
