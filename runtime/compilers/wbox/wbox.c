/* wbox — a multicall coreutils for the in-WASM shell (wb-9ja).
 *
 * One wasm binary; the applet is argv[1] (the host registers it as the command
 * "wbox" and Workbooks.Shell invokes it as `wbox <applet> <args...>`). This gives
 * the agent's shell real coreutils — echo/cat/seq/head/wc/… — entirely inside
 * WebAssembly, with NO OS process and NO fork/exec. The shell orchestrates the
 * pipes (host-side, trusted); every command runs here, in the sandbox.
 *
 * Compiled on first use via Workbooks.Compilers.compile_c (clang.wasm + wasm-ld,
 * wasm32-wasip1). IO is RAW read(0)/write(1)/write(2) + snprintf — buffered FILE*
 * stdio (getchar/putchar/printf) traps under this wasi-libc/heap config
 * (lazy buffer alloc faults in the small linear memory); raw syscalls are safe.
 */
#include <fcntl.h>   /* open (read files from a WASI preopen) */
#include <stdio.h>   /* snprintf */
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void w(const char *s, long n) {
  while (n > 0) {
    long k = write(1, s, (size_t)n);
    if (k <= 0) break;
    s += k;
    n -= k;
  }
}
static void ws(const char *s) { w(s, (long)strlen(s)); }

static int cat_fd(int fd) {
  char b[4096];
  long n;
  while ((n = read(fd, b, sizeof b)) > 0) w(b, n);
  return 0;
}

static int do_cat(int c, char **v) {
  if (c == 0) return cat_fd(0);  /* no args → stdin */
  int rc = 0;
  for (int i = 0; i < c; i++) {
    int fd = open(v[i], O_RDONLY);
    if (fd < 0) { write(2, "cat: cannot open file\n", 22); rc = 1; continue; }
    cat_fd(fd);
    close(fd);
  }
  return rc;
}

static int do_echo(int c, char **v) {
  int start = 0, nl = 1;
  if (c > 0 && strcmp(v[0], "-n") == 0) { nl = 0; start = 1; }
  for (int i = start; i < c; i++) {
    if (i > start) w(" ", 1);
    ws(v[i]);
  }
  if (nl) w("\n", 1);
  return 0;
}

static int do_seq(int c, char **v) {
  long lo = 1, hi = 0, step = 1;
  if (c == 1) hi = atol(v[0]);
  else if (c == 2) { lo = atol(v[0]); hi = atol(v[1]); }
  else if (c >= 3) { lo = atol(v[0]); step = atol(v[1]); hi = atol(v[2]); }
  if (step == 0) return 1;
  char buf[32];
  for (long i = lo; (step > 0) ? (i <= hi) : (i >= hi); i += step) {
    int k = snprintf(buf, sizeof buf, "%ld\n", i);
    w(buf, k);
  }
  return 0;
}

static int do_wc(int c, char **v) {
  char b[4096];
  long n, lines = 0, words = 0, bytes = 0;
  int inw = 0;
  while ((n = read(0, b, sizeof b)) > 0) {
    for (long i = 0; i < n; i++) {
      char ch = b[i];
      bytes++;
      if (ch == '\n') lines++;
      if (ch == ' ' || ch == '\t' || ch == '\n') inw = 0;
      else if (!inw) { inw = 1; words++; }
    }
  }
  char buf[64];
  int flagged = 0;
  for (int i = 0; i < c; i++) {
    if (!strcmp(v[i], "-l")) { w(buf, snprintf(buf, sizeof buf, "%ld\n", lines)); flagged = 1; }
    else if (!strcmp(v[i], "-w")) { w(buf, snprintf(buf, sizeof buf, "%ld\n", words)); flagged = 1; }
    else if (!strcmp(v[i], "-c")) { w(buf, snprintf(buf, sizeof buf, "%ld\n", bytes)); flagged = 1; }
  }
  if (!flagged) w(buf, snprintf(buf, sizeof buf, "%ld %ld %ld\n", lines, words, bytes));
  return 0;
}

static int do_head(int c, char **v) {
  long lim = 10;
  for (int i = 0; i < c; i++) {
    if (!strcmp(v[i], "-n") && i + 1 < c) lim = atol(v[i + 1]);
    else if (!strncmp(v[i], "-n", 2) && v[i][2]) lim = atol(v[i] + 2);
  }
  char b[4096];
  long n, ln = 0;
  while (ln < lim && (n = read(0, b, sizeof b)) > 0) {
    long i = 0;
    for (; i < n && ln < lim; i++)
      if (b[i] == '\n') ln++;
    w(b, i);
  }
  return 0;
}

static int do_nl(void) {
  char b[4096];
  long n, ln = 1;
  int at_start = 1;
  while ((n = read(0, b, sizeof b)) > 0) {
    for (long i = 0; i < n; i++) {
      if (at_start) {
        char num[32];
        w(num, snprintf(num, sizeof num, "%6ld\t", ln));
        at_start = 0;
      }
      w(b + i, 1);
      if (b[i] == '\n') { ln++; at_start = 1; }
    }
  }
  return 0;
}

static int do_rev(void) {
  char line[4096], r[4096], b[4096];
  long li = 0, n;
  while ((n = read(0, b, sizeof b)) > 0) {
    for (long i = 0; i < n; i++) {
      if (b[i] == '\n') {
        for (long j = 0; j < li; j++) r[j] = line[li - 1 - j];
        w(r, li);
        w("\n", 1);
        li = 0;
      } else if (li < (long)sizeof line) {
        line[li++] = b[i];
      }
    }
  }
  if (li > 0) {
    for (long j = 0; j < li; j++) r[j] = line[li - 1 - j];
    w(r, li);
  }
  return 0;
}

static int do_basename(int c, char **v) {
  if (c < 1) return 1;
  char *p = v[0], *s = strrchr(p, '/');
  char *base = s ? s + 1 : p;
  long bl = (long)strlen(base);
  if (c >= 2) {
    long sl = (long)strlen(v[1]);
    if (sl > 0 && sl < bl && !strcmp(base + bl - sl, v[1])) bl -= sl;
  }
  w(base, bl);
  w("\n", 1);
  return 0;
}

static int do_dirname(int c, char **v) {
  if (c < 1) { w(".\n", 2); return 1; }
  char *p = v[0], *s = strrchr(p, '/');
  if (!s) { w(".\n", 2); return 0; }
  if (s == p) { w("/\n", 2); return 0; }
  w(p, s - p);
  w("\n", 1);
  return 0;
}

static int do_tr(int c, char **v) {
  char b[4096];
  long n;
  if (c >= 2 && !strcmp(v[0], "-d")) {
    const char *set = v[1];
    char o[4096];
    while ((n = read(0, b, sizeof b)) > 0) {
      long oi = 0;
      for (long i = 0; i < n; i++)
        if (b[i] && !strchr(set, b[i])) o[oi++] = b[i];
      w(o, oi);
    }
    return 0;
  }
  if (c < 2) return 1;
  const char *s1 = v[0], *s2 = v[1];
  long l2 = (long)strlen(s2);
  while ((n = read(0, b, sizeof b)) > 0) {
    for (long i = 0; i < n; i++) {
      if (!b[i]) continue;
      const char *p = strchr(s1, b[i]);
      if (p) {
        long idx = p - s1;
        b[i] = idx < l2 ? s2[idx] : (l2 > 0 ? s2[l2 - 1] : b[i]);
      }
    }
    w(b, n);
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 2) { write(2, "wbox: missing applet\n", 21); return 2; }
  const char *a = argv[1];
  int c = argc - 2;
  char **v = argv + 2;

  if (!strcmp(a, "cat")) return do_cat(c, v);
  if (!strcmp(a, "echo")) return do_echo(c, v);
  if (!strcmp(a, "seq")) return do_seq(c, v);
  if (!strcmp(a, "wc")) return do_wc(c, v);
  if (!strcmp(a, "head")) return do_head(c, v);
  if (!strcmp(a, "nl")) return do_nl();
  if (!strcmp(a, "rev")) return do_rev();
  if (!strcmp(a, "basename")) return do_basename(c, v);
  if (!strcmp(a, "dirname")) return do_dirname(c, v);
  if (!strcmp(a, "tr")) return do_tr(c, v);
  if (!strcmp(a, "true")) return 0;
  if (!strcmp(a, "false")) return 1;

  write(2, "wbox: unknown applet\n", 21);
  return 2;
}
