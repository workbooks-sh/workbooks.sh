/* wb JS harness (wb-fm0.4): a QuickJS host that runs an untrusted JS workbook component
 * ENTIRELY in the wasm sandbox. Provides the SAME contract the old native-javy lane did —
 * Javy.IO.readSync/writeSync (raw fd read/write) + console.log/print — plus TextEncoder/
 * TextDecoder (not built into quickjs-ng) via a JS prelude. The user JS is embedded as
 * wb_js_src/wb_js_len by a per-build js_src.c, so each program is a standalone wasm.
 *
 * No quickjs-libc (its POSIX bits — environ/signals/popen — don't exist under wasi). We bind
 * only what's needed straight onto wasi-libc read()/write(). */
#include "quickjs.h"
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>

extern const char wb_js_src[];
extern const unsigned wb_js_len;

/* readSync(fd, u8) / writeSync(fd, u8): operate on the TypedArray's backing buffer + offset. */
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
  ssize_t n = read(fd, p + off, len);
  return JS_NewInt32(ctx, (int32_t)n);
}

static JSValue wb_write(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  int32_t fd; if (JS_ToInt32(ctx, &fd, argv[0])) return JS_EXCEPTION;
  size_t off, len; uint8_t *p = ta_ptr(ctx, argv[1], &off, &len);
  if (!p) return JS_EXCEPTION;
  ssize_t n = write(fd, p + off, len);
  return JS_NewInt32(ctx, (int32_t)n);
}

static JSValue wb_log(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  for (int i = 0; i < argc; i++) {
    const char *s = JS_ToCString(ctx, argv[i]);
    if (s) { if (i) fputc(' ', stdout); fputs(s, stdout); JS_FreeCString(ctx, s); }
  }
  fputc('\n', stdout); fflush(stdout);
  return JS_UNDEFINED;
}

/* Minimal UTF-8 TextEncoder/TextDecoder (quickjs-ng has neither). */
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
    JSValue st = JS_GetPropertyStr(ctx, e, "stack");
    if (!JS_IsUndefined(st)) { const char *ss = JS_ToCString(ctx, st); if (ss){ fprintf(stderr, "%s\n", ss); JS_FreeCString(ctx, ss);} }
    JS_FreeValue(ctx, st);
    JS_FreeValue(ctx, e);
    err = 1;
  }
  JS_FreeValue(ctx, r);
  return err;
}

int main(void) {
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
  JS_SetPropertyStr(ctx, g, "print", JS_NewCFunction(ctx, wb_log, "print", 1));
  JS_FreeValue(ctx, g);

  int code = eval_str(ctx, PRELUDE, strlen(PRELUDE), "<prelude>");
  if (!code) code = eval_str(ctx, wb_js_src, wb_js_len, "<workbook>");

  /* drain the microtask queue (Promise/async) so top-level async work completes */
  JSContext *c1;
  for (;;) {
    int r = JS_ExecutePendingJob(rt, &c1);
    if (r <= 0) { if (r < 0) JS_FreeValue(ctx, JS_GetException(ctx)); break; }
  }
  JS_FreeContext(ctx);
  JS_FreeRuntime(rt);
  return code;
}
