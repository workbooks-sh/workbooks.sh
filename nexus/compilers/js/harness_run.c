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

/* ── Beam.* JS↔OTP interop (wb-wzgu) ──────────────────────────────────────────────────────────────
 * Host imports the Washy runtime fulfills (lib/washy.ex call_host clauses). Linear memory IS the QuickJS
 * heap, so we pass byte-offset pointers; the host reads/writes them directly. import_name matches the
 * call_host clause name; import_module is ignored by Washy. Handles are encoded-pid STRINGS, messages/
 * args/replies are JSON. */
#define WBEAM __attribute__((import_module("beam")))
WBEAM __attribute__((import_name("beam_self")))  extern int host_beam_self(int buf_ptr);
WBEAM __attribute__((import_name("beam_spawn"))) extern int host_beam_spawn(int src_ptr, int src_len, int out_ptr);
WBEAM __attribute__((import_name("beam_send")))  extern int host_beam_send(int to_ptr, int to_len, int msg_ptr, int msg_len);
WBEAM __attribute__((import_name("beam_call")))  extern int host_beam_call(int name_ptr, int name_len, int args_ptr, int args_len, int out_ptr);
WBEAM __attribute__((import_name("beam_recv")))  extern int host_beam_recv(int out_ptr);
WBEAM __attribute__((import_name("beam_link")))  extern int host_beam_link(int to_ptr, int to_len);
WBEAM __attribute__((import_name("beam_process_info"))) extern int host_beam_process_info(int to_ptr, int to_len, int out_ptr);
WBEAM __attribute__((import_name("beam_system_info")))  extern int host_beam_system_info(int out_ptr);
WBEAM __attribute__((import_name("timer_set")))   extern int host_timer_set(int id, int ms);
WBEAM __attribute__((import_name("timer_clear"))) extern int host_timer_clear(int id);

#define WB_OFF(p) ((int)(uintptr_t)(p))
#define BEAM_OUT_CAP (256 * 1024)

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

/* ── Beam.* C wrappers: marshal JS ↔ linear-memory pointers ↔ host imports ── */
static JSValue js_beam_self(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  char buf[256];
  int len = host_beam_self(WB_OFF(buf));
  if (len < 0 || len > (int)sizeof(buf)) return JS_NULL;
  return JS_NewStringLen(ctx, buf, len);
}
static JSValue js_beam_spawn(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  size_t slen; const char *s = JS_ToCStringLen(ctx, &slen, argv[0]);
  if (!s) return JS_EXCEPTION;
  char out[256];
  int len = host_beam_spawn(WB_OFF(s), (int)slen, WB_OFF(out));
  JS_FreeCString(ctx, s);
  if (len < 0 || len > (int)sizeof(out)) return JS_NULL;
  return JS_NewStringLen(ctx, out, len);
}
static JSValue js_beam_send(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  size_t tlen, mlen;
  const char *to = JS_ToCStringLen(ctx, &tlen, argv[0]);
  const char *msg = JS_ToCStringLen(ctx, &mlen, argv[1]);
  int r = (to && msg) ? host_beam_send(WB_OFF(to), (int)tlen, WB_OFF(msg), (int)mlen) : -1;
  if (to) JS_FreeCString(ctx, to);
  if (msg) JS_FreeCString(ctx, msg);
  return JS_NewInt32(ctx, r);
}
static JSValue js_beam_call(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  size_t nlen, alen;
  const char *name = JS_ToCStringLen(ctx, &nlen, argv[0]);
  const char *args = JS_ToCStringLen(ctx, &alen, argv[1]);
  char *out = malloc(BEAM_OUT_CAP);
  int len = (name && args && out) ? host_beam_call(WB_OFF(name), (int)nlen, WB_OFF(args), (int)alen, WB_OFF(out)) : -1;
  JSValue res = (len >= 0 && len <= BEAM_OUT_CAP && out) ? JS_NewStringLen(ctx, out, len) : JS_NewString(ctx, "null");
  if (name) JS_FreeCString(ctx, name);
  if (args) JS_FreeCString(ctx, args);
  if (out) free(out);
  return res;
}
static JSValue js_beam_recv(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  char *out = malloc(BEAM_OUT_CAP);
  int len = out ? host_beam_recv(WB_OFF(out)) : -1;
  JSValue res = (len >= 0 && len <= BEAM_OUT_CAP && out) ? JS_NewStringLen(ctx, out, len) : JS_NewString(ctx, "null");
  if (out) free(out);
  return res;
}
static JSValue js_beam_link(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  size_t tlen; const char *to = JS_ToCStringLen(ctx, &tlen, argv[0]);
  int r = to ? host_beam_link(WB_OFF(to), (int)tlen) : -1;
  if (to) JS_FreeCString(ctx, to);
  return JS_NewInt32(ctx, r);
}
static JSValue js_beam_process_info(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  size_t tlen = 0; const char *to = (argc > 0) ? JS_ToCStringLen(ctx, &tlen, argv[0]) : NULL;
  char *out = malloc(BEAM_OUT_CAP);
  int len = out ? host_beam_process_info(to ? WB_OFF(to) : 0, (int)tlen, WB_OFF(out)) : -1;
  JSValue res = (len >= 0 && len <= BEAM_OUT_CAP && out) ? JS_NewStringLen(ctx, out, len) : JS_NewString(ctx, "null");
  if (to) JS_FreeCString(ctx, to);
  if (out) free(out);
  return res;
}
static JSValue js_beam_system_info(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  char *out = malloc(BEAM_OUT_CAP);
  int len = out ? host_beam_system_info(WB_OFF(out)) : -1;
  JSValue res = (len >= 0 && len <= BEAM_OUT_CAP && out) ? JS_NewStringLen(ctx, out, len) : JS_NewString(ctx, "null");
  if (out) free(out);
  return res;
}
static JSValue js_timer_set(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  int32_t id = 0, ms = 0; JS_ToInt32(ctx, &id, argv[0]); JS_ToInt32(ctx, &ms, argv[1]);
  host_timer_set(id, ms); return JS_UNDEFINED;
}
static JSValue js_timer_clear(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  int32_t id = 0; JS_ToInt32(ctx, &id, argv[0]); host_timer_clear(id); return JS_UNDEFINED;
}

/* The Beam global: thin JS over the __beam_* host bridges. JSON across the boundary. __beam_dispatch is
 * the entry the host re-enters per delivered message (it pulls the message via __beam_recv). */
static const char *BEAM_PRELUDE =
  "globalThis.Beam={__cb:null,"
  "self(){return __beam_self();},"
  "spawn(s){return __beam_spawn(String(s));},"
  "send(p,m){return __beam_send(String(p),JSON.stringify(m));},"
  "call(n,...a){return JSON.parse(__beam_call(String(n),JSON.stringify(a)));},"
  "link(p){return __beam_link(String(p));},"
  "processInfo(p){return JSON.parse(__beam_process_info(p===undefined?'':String(p)));},"
  "systemInfo(){return JSON.parse(__beam_system_info());},"
  "onMessage(cb){this.__cb=cb;}};"
  "globalThis.__beam_dispatch=function(){if(Beam.__cb){Beam.__cb(JSON.parse(__beam_recv()));}};";

/* ── Node-core shim: a CommonJS `require` over the 80/20 pure-JS core modules. The prelude SOURCE lives
 * as per-module files in compilers/js/node/*.js (conflict-free fan-out); build.sh concatenates them in
 * filename order into the generated node_prelude.h, which defines `static const char *NODE_PRELUDE`.
 * The I/O modules (fs/net/http/crypto/…) are added as new node/NN_*.js files — no edit here. */
#include "node_prelude.h"

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

/* Persistent guest instance (wb-wzgu): _start (main) does setup once and RETURNS WITHOUT FREEING,
 * stashing the runtime/context in these statics; the host then re-enters `wb_dispatch` (an export) per
 * delivered message, reusing the same QuickJS heap so guest JS state survives across messages. (One-shot
 * runs are unaffected — the whole wasm linear memory is reclaimed by the host when the instance drops.) */
static JSRuntime *g_rt = NULL;
static JSContext *g_ctx = NULL;

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: qjs-run <file.js>\n"); return 2; }
  size_t len;
  char *src = read_file(argv[1], &len);
  if (!src) { fprintf(stderr, "qjs-run: cannot read %s\n", argv[1]); return 2; }

  g_rt = JS_NewRuntime();
  g_ctx = JS_NewContext(g_rt);
  JSRuntime *rt = g_rt;
  JSContext *ctx = g_ctx;
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

  /* Beam.* interop bridges (the BEAM_PRELUDE wraps these into globalThis.Beam). */
  JS_SetPropertyStr(ctx, g, "__beam_self",  JS_NewCFunction(ctx, js_beam_self,  "__beam_self", 0));
  JS_SetPropertyStr(ctx, g, "__beam_spawn", JS_NewCFunction(ctx, js_beam_spawn, "__beam_spawn", 1));
  JS_SetPropertyStr(ctx, g, "__beam_send",  JS_NewCFunction(ctx, js_beam_send,  "__beam_send", 2));
  JS_SetPropertyStr(ctx, g, "__beam_call",  JS_NewCFunction(ctx, js_beam_call,  "__beam_call", 2));
  JS_SetPropertyStr(ctx, g, "__beam_recv",  JS_NewCFunction(ctx, js_beam_recv,  "__beam_recv", 0));
  JS_SetPropertyStr(ctx, g, "__beam_link",  JS_NewCFunction(ctx, js_beam_link,  "__beam_link", 1));
  JS_SetPropertyStr(ctx, g, "__beam_process_info", JS_NewCFunction(ctx, js_beam_process_info, "__beam_process_info", 1));
  JS_SetPropertyStr(ctx, g, "__beam_system_info",  JS_NewCFunction(ctx, js_beam_system_info,  "__beam_system_info", 0));
  JS_SetPropertyStr(ctx, g, "__host_timer_set",   JS_NewCFunction(ctx, js_timer_set,   "__host_timer_set", 2));
  JS_SetPropertyStr(ctx, g, "__host_timer_clear", JS_NewCFunction(ctx, js_timer_clear, "__host_timer_clear", 1));
  JS_FreeValue(ctx, g);

  int code = eval_str(ctx, PRELUDE, strlen(PRELUDE), "<prelude>");
  if (!code) code = eval_str(ctx, BEAM_PRELUDE, strlen(BEAM_PRELUDE), "<beam>");
  if (!code) code = eval_str(ctx, NODE_PRELUDE, strlen(NODE_PRELUDE), "<node>");
  if (!code) code = eval_str(ctx, src, len, argv[1]);
  free(src);

  JSContext *c1;
  for (;;) { int r = JS_ExecutePendingJob(rt, &c1); if (r <= 0) { if (r < 0) JS_FreeValue(ctx, JS_GetException(ctx)); break; } }
  /* NB: do NOT free g_ctx/g_rt here — a persistent guest re-enters via wb_dispatch. */
  return code;
}

/* wb_dispatch: re-enter the guest for ONE delivered message, reusing the persistent context (so guest JS
 * state survives). The host stashes the message (JSON) where __beam_recv reads it, then invokes this
 * export; it calls the JS __beam_dispatch() (which pulls the inbox + invokes the registered onMessage). */
__attribute__((export_name("wb_dispatch")))
int wb_dispatch(void) {
  if (!g_ctx) return -1;
  JSValue g = JS_GetGlobalObject(g_ctx);
  JSValue f = JS_GetPropertyStr(g_ctx, g, "__beam_dispatch");
  int rc = 0;

  if (JS_IsFunction(g_ctx, f)) {
    JSValue r = JS_Call(g_ctx, f, JS_UNDEFINED, 0, NULL);
    if (JS_IsException(r)) {
      JSValue e = JS_GetException(g_ctx);
      const char *s = JS_ToCString(g_ctx, e);
      fprintf(stderr, "wb_dispatch error: %s\n", s ? s : "(unknown)");
      if (s) JS_FreeCString(g_ctx, s);
      JS_FreeValue(g_ctx, e);
      rc = 1;
    }
    JS_FreeValue(g_ctx, r);
  }

  JS_FreeValue(g_ctx, f);
  JS_FreeValue(g_ctx, g);

  JSContext *c1;
  for (;;) { int r = JS_ExecutePendingJob(g_rt, &c1); if (r <= 0) { if (r < 0) JS_FreeValue(g_ctx, JS_GetException(g_ctx)); break; } }
  return rc;
}

/* wb_timer: the host re-enters here when a BEAM timer armed via __host_timer_set fires. Runs the JS
 * timer callback for `id` (via __wb_fire_timer), then drains promise microtasks. Same persistent-context
 * model as wb_dispatch — this is the async-completion contract for the timer source (wb-5q8w). */
__attribute__((export_name("wb_timer")))
int wb_timer(int id) {
  if (!g_ctx) return -1;
  JSValue g = JS_GetGlobalObject(g_ctx);
  JSValue f = JS_GetPropertyStr(g_ctx, g, "__wb_fire_timer");
  int rc = 0;

  if (JS_IsFunction(g_ctx, f)) {
    JSValue a = JS_NewInt32(g_ctx, id);
    JSValue r = JS_Call(g_ctx, f, JS_UNDEFINED, 1, &a);
    if (JS_IsException(r)) {
      JSValue e = JS_GetException(g_ctx);
      const char *s = JS_ToCString(g_ctx, e);
      fprintf(stderr, "wb_timer error: %s\n", s ? s : "(unknown)");
      if (s) JS_FreeCString(g_ctx, s);
      JS_FreeValue(g_ctx, e);
      rc = 1;
    }
    JS_FreeValue(g_ctx, r);
    JS_FreeValue(g_ctx, a);
  }

  JS_FreeValue(g_ctx, f);
  JS_FreeValue(g_ctx, g);

  JSContext *c1;
  for (;;) { int r = JS_ExecutePendingJob(g_rt, &c1); if (r <= 0) { if (r < 0) JS_FreeValue(g_ctx, JS_GetException(g_ctx)); break; } }
  return rc;
}
