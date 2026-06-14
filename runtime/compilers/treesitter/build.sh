#!/usr/bin/env bash
# Provision the tree-sitter lane: fetch the core runtime + the C grammar, stage a flat build dir for build_c_dir
# (core lib/src amalgam via lib.c; the other core .c are include_only; nested tree_sitter/ + unicode/ header dirs
# from the C grammar; grammar parser.c renamed to dodge the core parser.c collision). Parses real C source -> AST.
# Any tree-sitter grammar swaps in the same way. Last stdout = src dir.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; TSV="0.22.6"; TCV="0.21.4"; TSSHA="e2b687f74358ab6404730b7fb1a1ced7ddb3780202d37595ecd7b20a8f41861f"; TCSHA="19194c47a6faf81509aea338b96dd9b59ffd8a7f26bce6487cf4275065433870"
exec 3>&1 1>&2
if [ -f "$SRC/lib.c" ] && [ -f "$SRC/driver.c" ]; then echo "[ts] up to date"; echo "$SRC" 1>&3; exit 0; fi
TS="$SD/ts-$TSV.tar.gz"; TC="$SD/tsc-$TCV.tar.gz"
[ -f "$TS" ] || curl -fsSL "https://github.com/tree-sitter/tree-sitter/archive/refs/tags/v$TSV.tar.gz" -o "$TS"
[ -f "$TC" ] || curl -fsSL "https://github.com/tree-sitter/tree-sitter-c/archive/refs/tags/v$TCV.tar.gz" -o "$TC"
echo "$TSSHA  $TS" | shasum -a 256 -c -; echo "$TCSHA  $TC" | shasum -a 256 -c -
rm -rf "$SRC" "$SD/.tstmp"; mkdir -p "$SRC/tree_sitter" "$SRC/unicode" "$SD/.tstmp"
tar xzf "$TS" -C "$SD/.tstmp"; tar xzf "$TC" -C "$SD/.tstmp"
C="$SD/.tstmp/tree-sitter-$TSV"; G="$SD/.tstmp/tree-sitter-c-$TCV"
cp "$C/lib/src/"*.c "$C/lib/src/"*.h "$SRC/"
cp "$C/lib/src/unicode/"*.h "$SRC/unicode/"
cp "$C/lib/include/tree_sitter/"*.h "$SRC/tree_sitter/"   # api.h
cp "$G/src/tree_sitter/"*.h "$SRC/tree_sitter/"            # parser.h/alloc.h/array.h (has TSCharacterRange)
cp "$G/src/parser.c" "$SRC/c_parser.c"
rm -rf "$SD/.tstmp"
cat > "$SRC/driver.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tree_sitter/api.h"
const TSLanguage *tree_sitter_c(void);
int main(void){
  TSParser* p = ts_parser_new();
  ts_parser_set_language(p, tree_sitter_c());
  const char* src = "int add(int a, int b) { return a + b; }";
  TSTree* t = ts_parser_parse_string(p, NULL, src, (uint32_t)strlen(src));
  TSNode root = ts_tree_root_node(t);
  char* s = ts_node_string(root);
  printf("root=%s has_func=%d\n", ts_node_type(root), strstr(s,"function_definition")!=0);
  free(s); ts_tree_delete(t); ts_parser_delete(p);
  return 0;
}
C
echo "[ts] staged $(ls "$SRC"/*.c|wc -l|tr -d ' ') C files -> $SRC"; echo "$SRC" 1>&3
