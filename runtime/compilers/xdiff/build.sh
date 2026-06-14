#!/usr/bin/env bash
# Provision the xdiff (text diffing — the git diff engine) lane: fetch libgit2's standalone xdiff/, add a
# minimal git-xdiff.h shim (xdl_malloc->malloc etc; funcname-regex stubbed) + a unified-diff driver, stage for
# build_c_dir. Pinned to the libgit2 v1.8.1 tag (immutable). Last stdout = src dir.
set -euo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"; SRC="$SD/src"; TAG="v1.8.1"
exec 3>&1 1>&2
if [ -f "$SRC/xdiffi.c" ] && [ -f "$SRC/driver.c" ]; then echo "[xdiff] up to date"; echo "$SRC" 1>&3; exit 0; fi
rm -rf "$SRC"; mkdir -p "$SRC"
BASE="https://raw.githubusercontent.com/libgit2/libgit2/$TAG/deps/xdiff"
for f in xdiff.h xdiffi.c xdiffi.h xemit.c xemit.h xhistogram.c xinclude.h xmacros.h xmerge.c xpatience.c xprepare.c xprepare.h xtypes.h xutils.c xutils.h; do
  curl -fsSL "$BASE/$f" -o "$SRC/$f"
done
[ -s "$SRC/xdiffi.c" ] || { echo "[xdiff] fetch failed"; exit 1; }
cat > "$SRC/git-xdiff.h" <<'H'
#ifndef GIT_XDIFF_H
#define GIT_XDIFF_H
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <ctype.h>
#define xdl_malloc(x)        malloc(x)
#define xdl_calloc(n,sz)     calloc(n,sz)
#define xdl_free(ptr)        free(ptr)
#define xdl_realloc(ptr,x)   realloc(ptr,x)
#define XDL_BUG(msg)         abort()
#define XDL_UNUSED           __attribute__((__unused__))
typedef struct { int n; } xdl_regmatch_t;
typedef struct { int n; } xdl_regex_t;
#define xdl_regexec_buf(preg,buf,size,nmatch,pmatch,eflags) (-1)
#define xdl_regfree(preg) ((void)0)
#endif
H
cat > "$SRC/driver.c" <<'C'
#include <stdio.h>
#include <string.h>
#include "xdiff.h"
static char out[16384]; static int olen=0;
static int out_line(void* priv, mmbuffer_t* mb, int nbuf){
  (void)priv;
  for(int i=0;i<nbuf;i++){ memcpy(out+olen, mb[i].ptr, (size_t)mb[i].size); olen += (int)mb[i].size; }
  out[olen]=0; return 0;
}
int main(void){
  char a[] = "alpha\nbeta\ngamma\n";
  char b[] = "alpha\nBETA\ngamma\n";
  mmfile_t fa, fb; fa.ptr=a; fa.size=(long)strlen(a); fb.ptr=b; fb.size=(long)strlen(b);
  xpparam_t xpp; memset(&xpp,0,sizeof xpp);
  xdemitconf_t cfg; memset(&cfg,0,sizeof cfg); cfg.ctxlen=1;
  xdemitcb_t ecb; memset(&ecb,0,sizeof ecb); ecb.out_line=out_line;
  int rc = xdl_diff(&fa,&fb,&xpp,&cfg,&ecb);
  printf("rc=%d\n%s", rc, out);
  return 0;
}
C
echo "[xdiff] staged -> $SRC"; echo "$SRC" 1>&3
