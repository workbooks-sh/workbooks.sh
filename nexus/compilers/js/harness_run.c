/* wb generic QuickJS runner (wb-fm0.6): reads a JS file path from argv[1], evals it in the
 * sandbox with the same host surface as harness.c (Javy.IO + console + TextEncoder/Decoder).
 * Unlike harness.c (which embeds one program → a standalone wasm), this runs an ARBITRARY JS
 * file given at runtime — used to run the TypeScript compiler (typescript.js) in-sandbox to
 * transpile TS→JS before the JS lane compiles the result. Built ONCE into qjs-run.wasm. */
#include "quickjs.h"
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>

static uint8_t *ta_ptr(JSContext *ctx, JSValueConst ta, size_t *off, size_t *len) {
  size_t boff, blen, bpe;
  JSValue ab = JS_GetTypedArrayBuffer(ctx, ta, &boff, &blen, &bpe);
  if (JS_IsException(ab)) return NULL;
  size_t ab_size;
  uint8_t *base = JS_GetArrayBuffer(ctx, &ab_size, ab);
  JS_FreeValue(ctx, ab);
  if (!base) return NULL;
  *off = boff; *len = blen;
  return base;
}
static JSValue wb_read(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  int32_t fd; if (JS_ToInt32(ctx, &fd, argv[0])) return JS_EXCEPTION;
  size_t off, len; uint8_t *p = ta_ptr(ctx, argv[1], &off, &len);
  if (!p) return JS_EXCEPTION;
  return JS_NewInt32(ctx, (int32_t)read(fd, p + off, len));
}
static JSValue wb_write(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  int32_t fd; if (JS_ToInt32(ctx, &fd, argv[0])) return JS_EXCEPTION;
  size_t off, len; uint8_t *p = ta_ptr(ctx, argv[1], &off, &len);
  if (!p) return JS_EXCEPTION;
  return JS_NewInt32(ctx, (int32_t)write(fd, p + off, len));
}
static JSValue wb_log(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  for (int i = 0; i < argc; i++) {
    const char *s = JS_ToCString(ctx, argv[i]);
    if (s) { if (i) fputc(' ', stderr); fputs(s, stderr); JS_FreeCString(ctx, s); }
  }
  fputc('\n', stderr); fflush(stderr);  /* logs → stderr so they don't pollute the JS output on stdout */
  return JS_UNDEFINED;
}

static const char *PRELUDE =
  "globalThis.TextEncoder=class{encode(s){s=String(s);let b=[];for(let i=0;i<s.length;i++){"
  "let c=s.codePointAt(i);if(c>0xffff)i++;if(c<0x80)b.push(c);else if(c<0x800)b.push(0xc0|c>>6,0x80|c&63);"
  "else if(c<0x10000)b.push(0xe0|c>>12,0x80|(c>>6)&63,0x80|c&63);else b.push(0xf0|c>>18,0x80|(c>>12)&63,0x80|(c>>6)&63,0x80|c&63);}"
  "return new Uint8Array(b);}};"
  "globalThis.TextDecoder=class{decode(u){u=u?(u.buffer?new Uint8Array(u.buffer,u.byteOffset||0,u.byteLength):new Uint8Array(u)):new Uint8Array(0);"
  "let s='',i=0;while(i<u.length){let c=u[i++];if(c>=0xf0)c=(c&7)<<18|(u[i++]&63)<<12|(u[i++]&63)<<6|(u[i++]&63);"
  "else if(c>=0xe0)c=(c&15)<<12|(u[i++]&63)<<6|(u[i++]&63);else if(c>=0x80)c=(c&31)<<6|(u[i++]&63);s+=String.fromCodePoint(c);}return s;}};";

static int eval_str(JSContext *ctx, const char *src, size_t len, const char *name) {
  JSValue r = JS_Eval(ctx, src, len, name, JS_EVAL_TYPE_GLOBAL);
  int err = 0;
  if (JS_IsException(r)) {
    JSValue e = JS_GetException(ctx);
    const char *s = JS_ToCString(ctx, e);
    fprintf(stderr, "JS error: %s\n", s ? s : "(unknown)");
    if (s) JS_FreeCString(ctx, s);
    JS_FreeValue(ctx, e);
    err = 1;
  }
  JS_FreeValue(ctx, r);
  return err;
}

/* read an entire file into a NUL-terminated heap buffer; *len excludes the NUL */
static char *read_file(const char *path, size_t *len) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return NULL;
  size_t cap = 1 << 20, n = 0;
  char *buf = malloc(cap);
  if (!buf) { close(fd); return NULL; }
  for (;;) {
    if (n + 65536 + 1 > cap) { cap *= 2; char *nb = realloc(buf, cap); if (!nb) { free(buf); close(fd); return NULL; } buf = nb; }
    ssize_t r = read(fd, buf + n, 65536);
    if (r < 0) { free(buf); close(fd); return NULL; }
    if (r == 0) break;
    n += (size_t)r;
  }
  close(fd);
  buf[n] = 0; *len = n;
  return buf;
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: qjs-run <file.js>\n"); return 2; }
  size_t len;
  char *src = read_file(argv[1], &len);
  if (!src) { fprintf(stderr, "qjs-run: cannot read %s\n", argv[1]); return 2; }

  JSRuntime *rt = JS_NewRuntime();
  JSContext *ctx = JS_NewContext(rt);
  JSValue g = JS_GetGlobalObject(ctx);

  JSValue io = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, io, "readSync",  JS_NewCFunction(ctx, wb_read,  "readSync", 2));
  JS_SetPropertyStr(ctx, io, "writeSync", JS_NewCFunction(ctx, wb_write, "writeSync", 2));
  JSValue javy = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, javy, "IO", io);
  JS_SetPropertyStr(ctx, g, "Javy", javy);
  JSValue console = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, console, "log",   JS_NewCFunction(ctx, wb_log, "log", 1));
  JS_SetPropertyStr(ctx, console, "error", JS_NewCFunction(ctx, wb_log, "error", 1));
  JS_SetPropertyStr(ctx, g, "console", console);
  JS_FreeValue(ctx, g);

  int code = eval_str(ctx, PRELUDE, strlen(PRELUDE), "<prelude>");
  if (!code) code = eval_str(ctx, src, len, argv[1]);
  free(src);

  JSContext *c1;
  for (;;) { int r = JS_ExecutePendingJob(rt, &c1); if (r <= 0) { if (r < 0) JS_FreeValue(ctx, JS_GetException(ctx)); break; } }
  JS_FreeContext(ctx); JS_FreeRuntime(rt);
  return code;
}
