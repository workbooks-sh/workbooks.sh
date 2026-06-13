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
/* Brokered HTTP with an arbitrary method + headers + body (POST/PUT/…). headers = newline-joined
 * "k:v" lines. Returns the response-body byte count, or -1. */
__attribute__((import_module("env"), import_name("host_http")))
extern int host_http(const char *method, int method_len, const char *url, int url_len,
                     const char *hdr, int hdr_len, const char *body, int body_len,
                     char *out, int out_cap);
/* Brokered exec: req is the ExecBroker length-prefixed wire (see exec_broker.ex parse_request):
 *   [name_len:u32][name][argc:u32][(arg_len:u32)(arg)]*[stdin_len:u32][stdin]  (all LE). */
__attribute__((import_module("env"), import_name("host_exec")))
extern int host_exec(const char *req, int req_len, char *out, int out_cap);
/* Brokered raw TCP/UDP/TLS request→response (host:port, request bytes → response bytes). */
__attribute__((import_module("env"), import_name("host_tcp")))
extern int host_tcp(const char *host, int host_len, int port, const char *req, int req_len, char *out, int out_cap);
__attribute__((import_module("env"), import_name("host_udp")))
extern int host_udp(const char *host, int host_len, int port, const char *dgram, int dgram_len, char *out, int out_cap);
__attribute__((import_module("env"), import_name("host_tls")))
extern int host_tls(const char *host, int host_len, int port, const char *req, int req_len, char *out, int out_cap);

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
/* Javy.Net.request(method, url, body, headers) -> string | null. Brokered HTTP with an arbitrary
 * method/headers/body via host_http. `headers` may be a string ("k:v\nk2:v2") or an object
 * {k:v}; `body` may be a string (sent as UTF-8) or omitted. null on error / cap not granted. */
static JSValue wb_net_request(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  const char *method = argc > 0 ? JS_ToCString(ctx, argv[0]) : NULL;
  const char *url = argc > 1 ? JS_ToCString(ctx, argv[1]) : NULL;
  if (!method || !url) { if (method) JS_FreeCString(ctx, method); if (url) JS_FreeCString(ctx, url); return JS_NULL; }

  size_t blen = 0; const char *body = NULL;
  if (argc > 2 && !JS_IsUndefined(argv[2]) && !JS_IsNull(argv[2])) body = JS_ToCStringLen(ctx, &blen, argv[2]);

  /* headers: accept a string as-is, or flatten an object to "k:v\n" lines. */
  char *hdr = NULL; const char *hdr_cs = NULL; size_t hlen = 0;
  if (argc > 3 && JS_IsString(argv[3])) {
    hdr_cs = JS_ToCStringLen(ctx, &hlen, argv[3]);
  } else if (argc > 3 && JS_IsObject(argv[3])) {
    JSPropertyEnum *tab; uint32_t n;
    if (!JS_GetOwnPropertyNames(ctx, &tab, &n, argv[3], JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY)) {
      size_t cap = 256, len = 0; hdr = malloc(cap); if (hdr) hdr[0] = 0;
      for (uint32_t i = 0; hdr && i < n; i++) {
        const char *k = JS_AtomToCString(ctx, tab[i].atom);
        JSValue vv = JS_GetProperty(ctx, argv[3], tab[i].atom);
        const char *v = JS_ToCString(ctx, vv);
        if (k && v) {
          size_t need = len + strlen(k) + strlen(v) + 3;
          if (need > cap) { while (need > cap) cap *= 2; char *nb = realloc(hdr, cap); if (!nb) { free(hdr); hdr = NULL; } else hdr = nb; }
          if (hdr) len += snprintf(hdr + len, cap - len, "%s:%s\n", k, v);
        }
        if (k) JS_FreeCString(ctx, k);
        if (v) JS_FreeCString(ctx, v);
        JS_FreeValue(ctx, vv);
      }
      for (uint32_t i = 0; i < n; i++) JS_FreeAtom(ctx, tab[i].atom);
      js_free(ctx, tab);
      hlen = hdr ? len : 0;
    }
  }
  const char *hdr_ptr = hdr ? hdr : (hdr_cs ? hdr_cs : "");

  char *buf = malloc(WB_OUTCAP);
  JSValue r = JS_NULL;
  if (buf) {
    int rc = host_http(method, (int)strlen(method), url, (int)strlen(url),
                       hdr_ptr, (int)hlen, body ? body : "", (int)blen, buf, WB_OUTCAP);
    if (rc >= 0 && rc <= WB_OUTCAP) r = JS_NewStringLen(ctx, buf, rc);
    free(buf);
  }
  JS_FreeCString(ctx, method); JS_FreeCString(ctx, url);
  if (body) JS_FreeCString(ctx, body);
  if (hdr) free(hdr);
  if (hdr_cs) JS_FreeCString(ctx, hdr_cs);
  return r;
}

/* Build the ExecBroker length-prefixed wire into `dst` (must hold the worst case). Returns total
 * bytes written, or -1 on overflow. argv is a JS array of strings; stdin a string (may be ""). */
static void put_u32(char *p, uint32_t v) { p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; p[2] = (v >> 16) & 0xff; p[3] = (v >> 24) & 0xff; }

/* Javy.Exec.run(name, argv, stdin) -> string | null. argv: array of strings (or omitted); stdin:
 * string (or omitted). Dispatches through host_exec → ExecBroker (default-deny, registered-only). */
static JSValue wb_exec_run(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) {
  const char *name = argc > 0 ? JS_ToCString(ctx, argv[0]) : NULL;
  if (!name) return JS_NULL;

  /* collect argv strings */
  uint32_t ac = 0; const char **args = NULL; size_t *alens = NULL;
  if (argc > 1 && JS_IsArray(argv[1])) {
    JSValue lv = JS_GetPropertyStr(ctx, argv[1], "length");
    JS_ToUint32(ctx, &ac, lv); JS_FreeValue(ctx, lv);
    if (ac > 0) { args = calloc(ac, sizeof(char *)); alens = calloc(ac, sizeof(size_t)); }
    for (uint32_t i = 0; i < ac; i++) {
      JSValue e = JS_GetPropertyUint32(ctx, argv[1], i);
      args[i] = JS_ToCStringLen(ctx, &alens[i], e);
      JS_FreeValue(ctx, e);
    }
  }
  size_t slen = 0; const char *stdin_s = NULL;
  if (argc > 2 && !JS_IsUndefined(argv[2]) && !JS_IsNull(argv[2])) stdin_s = JS_ToCStringLen(ctx, &slen, argv[2]);

  /* size: nlen + name + argc + sum(alen+arg) + slen + stdin */
  size_t nlen = strlen(name);
  size_t total = 4 + nlen + 4;
  for (uint32_t i = 0; i < ac; i++) total += 4 + alens[i];
  total += 4 + slen;

  char *req = malloc(total);
  JSValue r = JS_NULL;
  if (req) {
    char *p = req;
    put_u32(p, (uint32_t)nlen); p += 4; memcpy(p, name, nlen); p += nlen;
    put_u32(p, ac); p += 4;
    for (uint32_t i = 0; i < ac; i++) { put_u32(p, (uint32_t)alens[i]); p += 4; if (alens[i]) memcpy(p, args[i], alens[i]); p += alens[i]; }
    put_u32(p, (uint32_t)slen); p += 4; if (slen) memcpy(p, stdin_s, slen); p += slen;

    char *buf = malloc(WB_OUTCAP);
    if (buf) {
      int rc = host_exec(req, (int)total, buf, WB_OUTCAP);
      if (rc >= 0 && rc <= WB_OUTCAP) r = JS_NewStringLen(ctx, buf, rc);
      free(buf);
    }
    free(req);
  }

  JS_FreeCString(ctx, name);
  for (uint32_t i = 0; i < ac; i++) if (args[i]) JS_FreeCString(ctx, args[i]);
  if (args) free(args);
  if (alens) free(alens);
  if (stdin_s) JS_FreeCString(ctx, stdin_s);
  return r;
}

/* Shared raw-socket bridge for tcp/tls (req/resp bytes) and udp (datagram/recv-one). */
static JSValue wb_raw_sock(JSContext *ctx, int argc, JSValueConst *argv,
                           int (*fn)(const char *, int, int, const char *, int, char *, int)) {
  const char *host = argc > 0 ? JS_ToCString(ctx, argv[0]) : NULL;
  int32_t port = 0; if (argc > 1) JS_ToInt32(ctx, &port, argv[1]);
  size_t rlen = 0; const char *req = argc > 2 ? JS_ToCStringLen(ctx, &rlen, argv[2]) : NULL;
  if (!host) { if (req) JS_FreeCString(ctx, req); return JS_NULL; }

  char *buf = malloc(WB_OUTCAP);
  JSValue r = JS_NULL;
  if (buf) {
    int rc = fn(host, (int)strlen(host), port, req ? req : "", (int)rlen, buf, WB_OUTCAP);
    if (rc >= 0 && rc <= WB_OUTCAP) r = JS_NewStringLen(ctx, buf, rc);
    free(buf);
  }
  JS_FreeCString(ctx, host);
  if (req) JS_FreeCString(ctx, req);
  return r;
}
/* Javy.Net.tcp(host, port, data) -> string | null. */
static JSValue wb_net_tcp(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return wb_raw_sock(ctx, argc, argv, host_tcp); }
/* Javy.Net.udp(host, port, datagram) -> string | null. */
static JSValue wb_net_udp(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return wb_raw_sock(ctx, argc, argv, host_udp); }
/* Javy.Net.tls(host, port, data) -> string | null. */
static JSValue wb_net_tls(JSContext *ctx, JSValueConst t, int argc, JSValueConst *argv) { return wb_raw_sock(ctx, argc, argv, host_tls); }

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
  "else if(c>=0xe0)c=(c&15)<<12|(u[i++]&63)<<6|(u[i++]&63);else if(c>=0x80)c=(c&31)<<6|(u[i++]&63);s+=String.fromCodePoint(c);}return s;}};"
  /* Net convenience helpers (defined after Javy is global). */
  "Javy.Net.post=function(u,b,h){return Javy.Net.request('POST',u,b,h);};"
  "Javy.Net.put=function(u,b,h){return Javy.Net.request('PUT',u,b,h);};";

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
  JS_SetPropertyStr(ctx, net, "get",     JS_NewCFunction(ctx, wb_net_get,     "get", 1));
  JS_SetPropertyStr(ctx, net, "request", JS_NewCFunction(ctx, wb_net_request, "request", 4));
  JS_SetPropertyStr(ctx, net, "tcp",     JS_NewCFunction(ctx, wb_net_tcp,     "tcp", 3));
  JS_SetPropertyStr(ctx, net, "udp",     JS_NewCFunction(ctx, wb_net_udp,     "udp", 3));
  JS_SetPropertyStr(ctx, net, "tls",     JS_NewCFunction(ctx, wb_net_tls,     "tls", 3));
  JS_SetPropertyStr(ctx, javy, "Net", net);
  JSValue exec = JS_NewObject(ctx);
  JS_SetPropertyStr(ctx, exec, "run", JS_NewCFunction(ctx, wb_exec_run, "run", 3));
  JS_SetPropertyStr(ctx, javy, "Exec", exec);
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
