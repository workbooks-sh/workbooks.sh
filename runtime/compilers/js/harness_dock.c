/* wb JS DOCK harness (wb-e1x.1 / JsDock): same as harness.c (Javy.IO + console + TextEncoder/
 * Decoder, embedded wb_js_src) PLUS Policy-gated host capability imports — host_http_get and
 * host_vfs_read/host_vfs_write — declared as wasm (import "env" ...) functions and exposed to JS
 * as Javy.Net.get(url) and Javy.VFS.read(path)/write(path,data).
 *
 * A command linked against THIS harness imports env.* and therefore must run under JsDock
 * (Workbooks.JsDock, via Wasmex) which backs those imports with Policy-gated Elixir host fns —
 * the npm analog of RustDock. It CANNOT run under the bare `wasmtime run` CLI (the imports would
 * be unsatisfied). Pure-compute JS commands keep using harness.c on the CLI lane unchanged.
 *
 * Untrusted JS still executes ONLY inside QuickJS-under-wasmtime; the host owns the actual fs/net
 * I/O (host-brokered egress, Route B). Zero native execution of untrusted source. */
#include "quickjs.h"
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>

extern const char wb_js_src[];
extern const unsigned wb_js_len;

/* ── env.* host capability imports (backed by Workbooks.JsDock over Wasmex) ──
 * Signatures mirror RustDock: caller passes wasm-memory pointers + lengths and an output buffer;
 * the host reads/writes that memory and returns the byte count (or -1 on error / missing). */
__attribute__((import_module("env"), import_name("host_http_get")))
extern int host_http_get(const char *url, int url_len, char *out, int out_cap);
__attribute__((import_module("env"), import_name("host_vfs_read")))
extern int host_vfs_read(const char *path, int path_len, char *out, int out_cap);
__attribute__((import_module("env"), import_name("host_vfs_write")))
extern int host_vfs_write(const char *path, int path_len, const char *data, int data_len);

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
    if (s) { if (i) fputc(' ', stdout); fputs(s, stdout); JS_FreeCString(ctx, s); }
  }
  fputc('\n', stdout); fflush(stdout);
  return JS_UNDEFINED;
}

#define WB_OUTCAP (4 * 1024 * 1024)

/* Javy.Net.get(url) -> string | null. Host-brokered HTTP GET (Browse); null on error or when the
 * cap isn't granted (the import is absent → JsDock supplies a stub returning -1). */
static JSValue wb_net_get(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  const char *url = JS_ToCString(ctx, argv[0]);
  if (!url) return JS_NULL;
  char *buf = malloc(WB_OUTCAP);
  if (!buf) { JS_FreeCString(ctx, url); return JS_NULL; }
  int n = host_http_get(url, (int)strlen(url), buf, WB_OUTCAP);
  JS_FreeCString(ctx, url);
  JSValue r = (n >= 0 && n <= WB_OUTCAP) ? JS_NewStringLen(ctx, buf, n) : JS_NULL;
  free(buf);
  return r;
}
/* Javy.VFS.read(path) -> string | null (null on missing/error). */
static JSValue wb_vfs_read_js(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  const char *path = JS_ToCString(ctx, argv[0]);
  if (!path) return JS_NULL;
  char *buf = malloc(WB_OUTCAP);
  if (!buf) { JS_FreeCString(ctx, path); return JS_NULL; }
  int n = host_vfs_read(path, (int)strlen(path), buf, WB_OUTCAP);
  JS_FreeCString(ctx, path);
  JSValue r = (n >= 0 && n <= WB_OUTCAP) ? JS_NewStringLen(ctx, buf, n) : JS_NULL;
  free(buf);
  return r;
}
/* Javy.VFS.write(path, data) -> bool. */
static JSValue wb_vfs_write_js(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  const char *path = JS_ToCString(ctx, argv[0]);
  size_t dlen; const char *data = JS_ToCStringLen(ctx, &dlen, argv[1]);
  if (!path || !data) { if (path) JS_FreeCString(ctx, path); if (data) JS_FreeCString(ctx, data); return JS_FALSE; }
  int rc = host_vfs_write(path, (int)strlen(path), data, (int)dlen);
  JS_FreeCString(ctx, path); JS_FreeCString(ctx, data);
  return rc == 0 ? JS_TRUE : JS_FALSE;
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

  /* JsDock capability bindings */
  JSValue net = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, net, "get", JS_NewCFunction(ctx, wb_net_get, "get", 1));
  JS_SetPropertyStr(ctx, javy, "Net", net);
  JSValue vfs = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, vfs, "read",  JS_NewCFunction(ctx, wb_vfs_read_js,  "read", 1));
  JS_SetPropertyStr(ctx, vfs, "write", JS_NewCFunction(ctx, wb_vfs_write_js, "write", 2));
  JS_SetPropertyStr(ctx, javy, "VFS", vfs);

  JS_SetPropertyStr(ctx, g, "Javy", javy);

  JSValue console = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, console, "log",   JS_NewCFunction(ctx, wb_log, "log", 1));
  JS_SetPropertyStr(ctx, console, "error", JS_NewCFunction(ctx, wb_log, "error", 1));
  JS_SetPropertyStr(ctx, g, "console", console);
  JS_SetPropertyStr(ctx, g, "print", JS_NewCFunction(ctx, wb_log, "print", 1));
  JS_FreeValue(ctx, g);

  int code = eval_str(ctx, PRELUDE, strlen(PRELUDE), "<prelude>");
  if (!code) code = eval_str(ctx, wb_js_src, wb_js_len, "<workbook>");

  JSContext *c1;
  for (;;) { int r = JS_ExecutePendingJob(rt, &c1); if (r <= 0) { if (r < 0) JS_FreeValue(ctx, JS_GetException(ctx)); break; } }
  JS_FreeContext(ctx);
  JS_FreeRuntime(rt);
  return code;
}
