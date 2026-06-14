#!/usr/bin/env bash
# Provision the tree-sitter lane: fetch the core runtime + the JSON grammar, stage a flat build dir for
# build_c_dir (core lib/src amalgam via lib.c; the other core .c are include_only; nested tree_sitter/ + unicode/
# header dirs; grammar parser.c renamed to avoid the core parser.c collision). Parses code -> AST. Last stdout = src.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; TSV="0.22.6"; JSV="0.21.0"; TSSHA="e2b687f74358ab6404730b7fb1a1ced7ddb3780202d37595ecd7b20a8f41861f"; JSSHA="83d89d297c475dceb1865a9eacd8da1008e1aecffb6137161361107665cbdf79"
exec 3>&1 1>&2
if [ -f "$SRC/lib.c" ] && [ -f "$SRC/driver.c" ]; then echo "[ts] up to date"; echo "$SRC" 1>&3; exit 0; fi
TS="$SD/ts-$TSV.tar.gz"; JS="$SD/tsjson-$JSV.tar.gz"
[ -f "$TS" ] || curl -fsSL "https://github.com/tree-sitter/tree-sitter/archive/refs/tags/v$TSV.tar.gz" -o "$TS"
[ -f "$JS" ] || curl -fsSL "https://github.com/tree-sitter/tree-sitter-json/archive/refs/tags/v$JSV.tar.gz" -o "$JS"
echo "$TSSHA  $TS" | shasum -a 256 -c -; echo "$JSSHA  $JS" | shasum -a 256 -c -
rm -rf "$SRC" "$SD/.tstmp"; mkdir -p "$SRC/tree_sitter" "$SRC/unicode" "$SD/.tstmp"
tar xzf "$TS" -C "$SD/.tstmp"; tar xzf "$JS" -C "$SD/.tstmp"
C="$SD/.tstmp/tree-sitter-$TSV"; J="$SD/.tstmp/tree-sitter-json-$JSV"
cp "$C/lib/src/"*.c "$C/lib/src/"*.h "$SRC/"
cp "$C/lib/src/unicode/"*.h "$SRC/unicode/"
cp "$C/lib/include/tree_sitter/"*.h "$SRC/tree_sitter/"
cp "$J/src/tree_sitter/"*.h "$SRC/tree_sitter/"
cp "$J/src/parser.c" "$SRC/json_parser.c"
rm -rf "$SD/.tstmp"
cat > "$SRC/driver.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tree_sitter/api.h"
const TSLanguage *tree_sitter_json(void);
int main(void){
  TSParser* p = ts_parser_new();
  ts_parser_set_language(p, tree_sitter_json());
  const char* src = "[1,2,3]";
  TSTree* t = ts_parser_parse_string(p, NULL, src, (uint32_t)strlen(src));
  TSNode root = ts_tree_root_node(t);
  char* s = ts_node_string(root);
  printf("root=%s sexp=%s\n", ts_node_type(root), s);
  free(s); ts_tree_delete(t); ts_parser_delete(p);
  return 0;
}
C
echo "[ts] staged $(ls "$SRC"/*.c|wc -l|tr -d ' ') C files -> $SRC"; echo "$SRC" 1>&3
