/* wasi has no process spawning / temp files / wall clock; stub so Lua links.
   os.execute / os.clock / io.tmpfile become no-ops — irrelevant in the sandbox. */
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
FILE *tmpfile(void) { return NULL; }
clock_t clock(void) { return (clock_t)0; }
int system(const char *cmd) { (void)cmd; return -1; }
