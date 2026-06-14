#!/usr/bin/env bash
# Provision the tinyexpr (math-expression evaluator) lane: fetch tinyexpr.c/.h (stable, no releases -> pinned
# by content sha), stage src/{tinyexpr.c,tinyexpr.h,driver.c} for build_c_dir. driver evaluates expressions +
# bound variables. Last stdout = src dir.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; CSHA="1d81271c9368b6ef676c6532f0d0c0d21a81104ac569f6832c61f8c717e781bb"
exec 3>&1 1>&2
if [ -f "$SRC/tinyexpr.c" ] && [ -f "$SRC/driver.c" ]; then echo "[tinyexpr] up to date"; echo "$SRC" 1>&3; exit 0; fi
mkdir -p "$SRC"
curl -fsSL "https://github.com/codeplea/tinyexpr/raw/master/tinyexpr.c" -o "$SRC/tinyexpr.c"
curl -fsSL "https://github.com/codeplea/tinyexpr/raw/master/tinyexpr.h" -o "$SRC/tinyexpr.h"
echo "$CSHA  $SRC/tinyexpr.c" | shasum -a 256 -c - || { echo "[tinyexpr] SHA MISMATCH (upstream changed)"; exit 1; }
cat > "$SRC/driver.c" <<'C'
#include <stdio.h>
#include "tinyexpr.h"
int main(void){
  double r1 = te_interp("3+4*2", 0);
  double r2 = te_interp("sqrt(9)+pow(2,3)", 0);
  double x = 5; te_variable vars[] = {{"x", &x, 0, 0}};
  int err;
  te_expr* e = te_compile("2*x+1", vars, 1, &err);
  double r3 = e ? te_eval(e) : -1;
  x = 10; double r4 = e ? te_eval(e) : -1;
  if(e) te_free(e);
  printf("a=%g b=%g c=%g d=%g\n", r1, r2, r3, r4);
  return 0;
}
C
echo "[tinyexpr] staged -> $SRC"; echo "$SRC" 1>&3
