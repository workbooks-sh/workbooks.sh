/*
 * posix_stub.c — definitions for the host-escape libc functions wasi-libc declares but never
 * provides, so real CLIs that reference them LINK and the escape simply FAILS at runtime instead
 * of breaking the build. This is sandbox-correct: the WASM sandbox intentionally has no host
 * process spawning or temp-file escape, so os.execute / io.popen / os.tmpname (Lua) and friends
 * should return an error, not link-fail the whole tool. Linked into every in-sandbox C build
 * alongside mmap_shim.c.
 *
 * (Functions wasi-libc DOES implement — remove/rename/getenv/time/clock — are untouched.)
 */
#include <stdio.h>
#include <stddef.h>

/* os.execute / system(3) → "no shell in the sandbox" */
int system(const char *command) {
  (void)command;
  return -1;
}

/* io.popen / popen(3) → no child process */
FILE *popen(const char *command, const char *type) {
  (void)command;
  (void)type;
  return NULL;
}

int pclose(FILE *stream) {
  (void)stream;
  return -1;
}

/* os.tmpname / tmpnam(3) → no temp-name service (L_tmpnam is -D'd by the C lane for the call site) */
char *tmpnam(char *s) {
  (void)s;
  return NULL;
}

/* io.tmpfile / tmpfile(3) → no anonymous temp file in the sandbox */
FILE *tmpfile(void) {
  return NULL;
}

/* dup(2) — wasi-libc omits the declaration AND symbol (no fd duplication in WASI). Define it so tools
 * that reference it (e.g. libxml2 xmlIO.c output path) LINK; the fd-dup escape simply fails at runtime.
 * Callers compile via -Wno-implicit-function-declaration (the decl is absent in wasi-libc). wb-u1ly. */
int dup(int oldfd) {
  (void)oldfd;
  return -1;
}
