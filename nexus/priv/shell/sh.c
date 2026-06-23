/* worgsh — a featured, NO-FORK shell that compiles to ONE wasm command module and runs in our in-house
 * wasm lane (clang.wasm -> wasm32-wasip1 -> AOT -> wasmtime, per-invocation). This is "bash in WASM":
 * the only thing a real shell needs fork/exec for is pipes between processes — here pipes are done by
 * BUFFERED CHAINING in one process (run a stage to completion, feed its output to the next). No fork,
 * no exec, no wasmer. Tools are BUILTINS compiled in (busybox-style). Files are read/written over the
 * mounted /work dir (a virtual fs). Featured, not real-bash: enough grammar for an agent's batch work.
 *
 * Invocation:  sh.wasm "<command line>"   (the command line is argv[1]; the program's stdin is the
 *              optional external input to the first stage). Output -> stdout.
 *
 * v0 grammar: pipelines `|`, sequencing `;`, `&&`, `||`, redirects `>`/`>>`, simple quoting.
 * v0 builtins: echo cat grep head tail wc sort uniq rev tr cut nl true false  (+ upper/lower helpers).
 * Everything is intentionally small + extensible: add a builtin = one row in the dispatch table.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ctype.h>
#include <fcntl.h>

/* ---- growable byte buffer (a "stream" between pipeline stages) ---------------------------------- */
typedef struct { char *p; size_t len, cap; } Buf;
static void bensure(Buf *b, size_t add) {
  if (b->len + add + 1 > b->cap) { b->cap = (b->len + add + 1) * 2 + 64; b->p = realloc(b->p, b->cap); }
}
static void bput(Buf *b, const char *s, size_t n) { bensure(b, n); memcpy(b->p + b->len, s, n); b->len += n; b->p[b->len] = 0; }
static void bputs(Buf *b, const char *s) { bput(b, s, strlen(s)); }
static void bputc_(Buf *b, char c) { bensure(b, 1); b->p[b->len++] = c; b->p[b->len] = 0; }
static void bfree(Buf *b) { free(b->p); b->p = 0; b->len = b->cap = 0; }

/* read a whole file from the cwd (/work) into a buffer; 0 on success */
static int read_file(const char *path, Buf *out) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return -1;
  char tmp[8192]; long n;
  while ((n = read(fd, tmp, sizeof tmp)) > 0) bput(out, tmp, (size_t)n);
  close(fd);
  return 0;
}

/* ---- builtins: each takes argv + an input stream, writes to an output stream --------------------- */
typedef struct { int argc; char **argv; Buf *in; Buf *out; } Ctx;

static void each_line(Buf *in, void (*fn)(const char *line, size_t len, void *u), void *u) {
  size_t i = 0;
  while (i < in->len) {
    size_t j = i;
    while (j < in->len && in->p[j] != '\n') j++;
    fn(in->p + i, j - i, u);
    i = (j < in->len) ? j + 1 : j;
  }
}

static int b_echo(Ctx *c) {
  for (int i = 1; i < c->argc; i++) { if (i > 1) bputc_(c->out, ' '); bputs(c->out, c->argv[i]); }
  bputc_(c->out, '\n'); return 0;
}
static int b_cat(Ctx *c) {
  if (c->argc <= 1) { bput(c->out, c->in->p, c->in->len); return 0; }
  int rc = 0;
  for (int i = 1; i < c->argc; i++) { Buf f = {0}; if (read_file(c->argv[i], &f) == 0) bput(c->out, f.p, f.len); else { bputs(c->out, "cat: "); bputs(c->out, c->argv[i]); bputs(c->out, ": No such file\n"); rc = 1; } bfree(&f); }
  return rc;
}
struct grep_u { const char *pat; Buf *out; int inv; };
static void grep_line(const char *l, size_t n, void *u) {
  struct grep_u *g = u; char *line = strndup(l, n);
  int hit = strstr(line, g->pat) != NULL;
  if (hit ^ g->inv) { bput(g->out, l, n); bputc_(g->out, '\n'); }
  free(line);
}
static int b_grep(Ctx *c) {
  int inv = 0, ai = 1;
  if (ai < c->argc && strcmp(c->argv[ai], "-v") == 0) { inv = 1; ai++; }
  if (ai >= c->argc) { bputs(c->out, "grep: need a pattern\n"); return 2; }
  struct grep_u g = { c->argv[ai], c->out, inv };
  /* additional file args: grep over those instead of stdin */
  if (ai + 1 < c->argc) { for (int i = ai + 1; i < c->argc; i++) { Buf f = {0}; if (read_file(c->argv[i], &f) == 0) each_line(&f, grep_line, &g); bfree(&f); } }
  else each_line(c->in, grep_line, &g);
  return 0;
}
struct nlim { int n, seen; Buf *out; };
static void head_line(const char *l, size_t n, void *u) { struct nlim *h = u; if (h->seen < h->n) { bput(h->out, l, n); bputc_(h->out, '\n'); h->seen++; } }
static int b_head(Ctx *c) { int n = 10, ai = 1; if (ai < c->argc && c->argv[ai][0] == '-') { n = atoi(c->argv[ai] + 1); ai++; } struct nlim h = { n, 0, c->out }; each_line(c->in, head_line, &h); return 0; }
static int count_lines(Buf *b) { int n = 0; for (size_t i = 0; i < b->len; i++) if (b->p[i] == '\n') n++; return n; }
static int b_tail(Ctx *c) {
  int n = 10, ai = 1; if (ai < c->argc && c->argv[ai][0] == '-') { n = atoi(c->argv[ai] + 1); ai++; }
  int total = count_lines(c->in), skip = total - n; if (skip < 0) skip = 0;
  struct nlim h = { 1<<30, 0, c->out }; (void)h;
  int seen = 0; size_t i = 0;
  while (i < c->in->len) { size_t j = i; while (j < c->in->len && c->in->p[j] != '\n') j++; if (seen >= skip) { bput(c->out, c->in->p + i, j - i); bputc_(c->out, '\n'); } seen++; i = (j < c->in->len) ? j + 1 : j; }
  return 0;
}
static int b_wc(Ctx *c) {
  long lines = 0, words = 0, bytes = (long)c->in->len; int inw = 0;
  for (size_t i = 0; i < c->in->len; i++) { char ch = c->in->p[i]; if (ch == '\n') lines++; if (isspace((unsigned char)ch)) inw = 0; else if (!inw) { inw = 1; words++; } }
  char t[64]; int wantl = 0, wantw = 0, wantc = 0;
  for (int i = 1; i < c->argc; i++) { if (!strcmp(c->argv[i], "-l")) wantl = 1; else if (!strcmp(c->argv[i], "-w")) wantw = 1; else if (!strcmp(c->argv[i], "-c")) wantc = 1; }
  if (!wantl && !wantw && !wantc) { snprintf(t, sizeof t, "%ld %ld %ld\n", lines, words, bytes); bputs(c->out, t); }
  else { if (wantl) { snprintf(t, sizeof t, "%ld\n", lines); bputs(c->out, t); } if (wantw) { snprintf(t, sizeof t, "%ld\n", words); bputs(c->out, t); } if (wantc) { snprintf(t, sizeof t, "%ld\n", bytes); bputs(c->out, t); } }
  return 0;
}
static int b_rev(Ctx *c) {
  size_t i = 0; while (i < c->in->len) { size_t j = i; while (j < c->in->len && c->in->p[j] != '\n') j++; for (size_t k = j; k > i; k--) bputc_(c->out, c->in->p[k - 1]); bputc_(c->out, '\n'); i = (j < c->in->len) ? j + 1 : j; }
  return 0;
}
static int cmp_lines(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
static int b_sort(Ctx *c) {
  int nl = count_lines(c->in) + 1; char **arr = calloc(nl, sizeof(char *)); int n = 0; size_t i = 0;
  while (i < c->in->len) { size_t j = i; while (j < c->in->len && c->in->p[j] != '\n') j++; arr[n++] = strndup(c->in->p + i, j - i); i = (j < c->in->len) ? j + 1 : j; }
  qsort(arr, n, sizeof(char *), cmp_lines);
  int rev = 0; for (int k = 1; k < c->argc; k++) if (!strcmp(c->argv[k], "-r")) rev = 1;
  for (int k = 0; k < n; k++) { char *s = arr[rev ? n - 1 - k : k]; bputs(c->out, s); bputc_(c->out, '\n'); free(arr[k]); }
  free(arr); return 0;
}
static int b_uniq(Ctx *c) {
  char *prev = 0; size_t i = 0;
  while (i < c->in->len) { size_t j = i; while (j < c->in->len && c->in->p[j] != '\n') j++; char *line = strndup(c->in->p + i, j - i); if (!prev || strcmp(prev, line) != 0) { bputs(c->out, line); bputc_(c->out, '\n'); } free(prev); prev = line; i = (j < c->in->len) ? j + 1 : j; }
  free(prev); return 0;
}
/* expand a tr SET, turning `a-z` ranges into the full sequence; returns a malloc'd string. */
static char *tr_expand(const char *s) {
  Buf b = {0};
  for (size_t i = 0; s[i]; i++) {
    if (s[i + 1] == '-' && s[i + 2] && s[i + 2] != 0) { for (char ch = s[i]; ch <= s[i + 2]; ch++) bputc_(&b, ch); i += 2; }
    else bputc_(&b, s[i]);
  }
  return b.p ? b.p : strdup("");
}
static int b_tr(Ctx *c) {
  if (c->argc < 3) { bputs(c->out, "tr: need SET1 SET2\n"); return 2; }
  char *a = tr_expand(c->argv[1]), *b = tr_expand(c->argv[2]); size_t la = strlen(a), lb = strlen(b);
  for (size_t i = 0; i < c->in->len; i++) { char ch = c->in->p[i]; const char *pos = memchr(a, ch, la); if (pos) { size_t idx = (size_t)(pos - a); bputc_(c->out, idx < lb ? b[idx] : b[lb ? lb - 1 : 0]); } else bputc_(c->out, ch); }
  free(a); free(b);
  return 0;
}
static int b_upper(Ctx *c) { for (size_t i = 0; i < c->in->len; i++) bputc_(c->out, (char)toupper((unsigned char)c->in->p[i])); return 0; }
static int b_lower(Ctx *c) { for (size_t i = 0; i < c->in->len; i++) bputc_(c->out, (char)tolower((unsigned char)c->in->p[i])); return 0; }
static int b_nl(Ctx *c) { int ln = 1; size_t i = 0; char t[32]; while (i < c->in->len) { size_t j = i; while (j < c->in->len && c->in->p[j] != '\n') j++; snprintf(t, sizeof t, "%6d\t", ln++); bputs(c->out, t); bput(c->out, c->in->p + i, j - i); bputc_(c->out, '\n'); i = (j < c->in->len) ? j + 1 : j; } return 0; }
static int b_true(Ctx *c) { (void)c; return 0; }
static int b_false(Ctx *c) { (void)c; return 1; }

typedef int (*Builtin)(Ctx *);
static struct { const char *name; Builtin fn; } TABLE[] = {
  {"echo", b_echo}, {"cat", b_cat}, {"grep", b_grep}, {"head", b_head}, {"tail", b_tail},
  {"wc", b_wc}, {"rev", b_rev}, {"sort", b_sort}, {"uniq", b_uniq}, {"tr", b_tr},
  {"upper", b_upper}, {"lower", b_lower}, {"nl", b_nl}, {"true", b_true}, {"false", b_false}, {0, 0}
};
static Builtin lookup(const char *name) { for (int i = 0; TABLE[i].name; i++) if (!strcmp(TABLE[i].name, name)) return TABLE[i].fn; return 0; }

/* ---- tokenizer: split a stage into argv, honoring '...' and "..." quotes ------------------------ */
static int tokenize(char *s, char **argv, int max) {
  int n = 0;
  while (*s && n < max - 1) {
    while (*s == ' ' || *s == '\t') s++;
    if (!*s) break;
    char *start; char q = 0;
    if (*s == '\'' || *s == '"') { q = *s++; start = s; while (*s && *s != q) s++; }
    else { start = s; while (*s && *s != ' ' && *s != '\t') s++; }
    if (*s) *s++ = 0;
    argv[n++] = start;
  }
  argv[n] = 0;
  return n;
}

/* run one pipeline (stages split by '|'); `extern_in` seeds the FIRST stage. Returns exit code; the
 * final stage's output is written to real stdout (or a redirect file). NO FORK — each stage runs to
 * completion and its buffer becomes the next stage's input. */
static int run_pipeline(char *pipe_str, Buf *extern_in) {
  /* split off a trailing redirect: `… > file` or `… >> file` */
  char *redir = 0; int append = 0;
  char *gt = strstr(pipe_str, ">");
  if (gt) { append = (gt[1] == '>'); *gt = 0; char *f = gt + (append ? 2 : 1); while (*f == ' ') f++; redir = f; char *e = f; while (*e && *e != ' ') e++; *e = 0; }

  Buf cur = {0};
  if (extern_in && extern_in->len) bput(&cur, extern_in->p, extern_in->len);

  int rc = 0; char *save; char *stage = strtok_r(pipe_str, "|", &save);
  while (stage) {
    char *argv[128]; int argc = tokenize(stage, argv, 128);
    Buf next = {0};
    if (argc == 0) { bfree(&next); stage = strtok_r(0, "|", &save); continue; }
    Builtin fn = lookup(argv[0]);
    if (!fn) { bputs(&next, argv[0]); bputs(&next, ": command not found\n"); rc = 127; }
    else { Ctx ctx = { argc, argv, &cur, &next }; rc = fn(&ctx); }
    bfree(&cur); cur = next;
    stage = strtok_r(0, "|", &save);
  }

  if (redir) { int fd = open(redir, O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC), 0644); if (fd >= 0) { write(fd, cur.p, cur.len); close(fd); } }
  else write(1, cur.p, cur.len);
  bfree(&cur);
  return rc;
}

/* split the whole line on `;`, `&&`, `||` and run each pipeline with short-circuit semantics. */
static int run_line(char *line, Buf *extern_in) {
  int rc = 0; char *p = line;
  while (*p) {
    /* find the next separator */
    char *q = p; char sep = ';';
    while (*q) { if (*q == ';') { sep = ';'; break; } if (q[0] == '&' && q[1] == '&') { sep = '&'; break; } if (q[0] == '|' && q[1] == '|') { sep = 'o'; break; } q++; }
    char *seg = p;
    if (*q) { *q = 0; p = q + ((sep == '&' || sep == 'o') ? 2 : 1); } else p = q;
    /* trim */
    while (*seg == ' ') seg++;
    if (*seg) {
      int prev = rc;
      /* short-circuit: after `&&` skip if prev failed; after `||` skip if prev succeeded */
      static char last_sep = ';';
      int skip = (last_sep == '&' && prev != 0) || (last_sep == 'o' && prev == 0);
      if (!skip) rc = run_pipeline(seg, (seg == line) ? extern_in : 0);
      last_sep = sep;
    }
  }
  return rc;
}

int main(int argc, char **argv) {
  Buf line = {0}, in = {0};
  if (argc >= 2) {
    /* command line via argv[1..]; the program's stdin is external data for the first stage. */
    for (int i = 1; i < argc; i++) { if (i > 1) bputc_(&line, ' '); bputs(&line, argv[i]); }
    char t[8192]; long n; while ((n = read(0, t, sizeof t)) > 0) bput(&in, t, (size_t)n);
  } else {
    /* no argv: the WHOLE stdin IS the command line (the agent's bash line). No external data — the
     * shell's inputs come from files in /work (cat /work/x | …). This is the run_command(wasm,line) path. */
    char t[8192]; long n; while ((n = read(0, t, sizeof t)) > 0) bput(&line, t, (size_t)n);
    /* strip a trailing newline so `echo hi\n` parses as `echo hi` */
    while (line.len && (line.p[line.len - 1] == '\n' || line.p[line.len - 1] == '\r')) line.p[--line.len] = 0;
  }
  int rc = run_line(line.p ? line.p : "", &in);
  bfree(&line); bfree(&in);
  /* WASI rejects exit codes outside [0,125] — clamp (the failure detail is in the output text). */
  if (rc < 0 || rc > 125) rc = 1;
  return rc;
}
