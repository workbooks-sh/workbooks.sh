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

/* ── Node-core shim: a CommonJS `require` over the 80/20 pure-JS core modules (no host/event-loop needed:
 * process/events/util/path/buffer/os/assert/querystring). Backed by OTP later for the I/O modules. The
 * entry's own deps are bundled by esbuild; require() only needs to resolve the externalized core modules. */
static const char *NODE_PRELUDE =
  "(function(){var M={};function def(n,m){M[n]=m;}"
  "globalThis.global=globalThis;"
  /* process */
  "var process=globalThis.process={argv:['node','/work/main'],argv0:'node',env:{},platform:'linux',arch:'wasm32',pid:1,ppid:0,"
  "version:'v18.19.0',versions:{node:'18.19.0',v8:'0'},title:'node',"
  "nextTick:function(f){var a=Array.prototype.slice.call(arguments,1);Promise.resolve().then(function(){f.apply(null,a);});},"
  "cwd:function(){return '/work';},chdir:function(){},exit:function(c){throw {__node_exit:c||0};},"
  "hrtime:function(p){return p?[0,0]:[0,0];},"
  "on:function(){return process;},once:function(){return process;},emit:function(){return false;},"
  "stdout:{write:function(s){Javy.IO.writeSync(1,new TextEncoder().encode(String(s)));return true;},isTTY:false},"
  "stderr:{write:function(s){Javy.IO.writeSync(2,new TextEncoder().encode(String(s)));return true;},isTTY:false}};"
  "process.hrtime.bigint=function(){return 0n;};def('process',process);"
  /* events */
  "function EventEmitter(){this._ev={};}"
  "EventEmitter.prototype.on=function(t,f){(this._ev[t]=this._ev[t]||[]).push(f);return this;};"
  "EventEmitter.prototype.addListener=EventEmitter.prototype.on;"
  "EventEmitter.prototype.prependListener=function(t,f){(this._ev[t]=this._ev[t]||[]).unshift(f);return this;};"
  "EventEmitter.prototype.once=function(t,f){var s=this;function g(){s.removeListener(t,g);return f.apply(this,arguments);}g.listener=f;return s.on(t,g);};"
  "EventEmitter.prototype.removeListener=function(t,f){var a=this._ev[t];if(a){var i=a.indexOf(f);if(i<0){for(i=0;i<a.length;i++){if(a[i].listener===f)break;}}if(i>-1&&i<a.length)a.splice(i,1);}return this;};"
  "EventEmitter.prototype.off=EventEmitter.prototype.removeListener;"
  "EventEmitter.prototype.removeAllListeners=function(t){if(t)delete this._ev[t];else this._ev={};return this;};"
  "EventEmitter.prototype.emit=function(t){var a=this._ev[t];if(!a||!a.length){if(t==='error')throw arguments[1];return false;}var ar=Array.prototype.slice.call(arguments,1);a.slice().forEach(function(f){f.apply(this,ar);},this);return true;};"
  "EventEmitter.prototype.listeners=function(t){return (this._ev[t]||[]).slice();};"
  "EventEmitter.prototype.listenerCount=function(t){return (this._ev[t]||[]).length;};"
  "EventEmitter.prototype.setMaxListeners=function(){return this;};EventEmitter.defaultMaxListeners=10;"
  "EventEmitter.once=function(em,t){return new Promise(function(r){em.once(t,function(){r(Array.prototype.slice.call(arguments));});});};"
  "def('events',EventEmitter);M['events'].EventEmitter=EventEmitter;"
  /* util */
  "function inspect(v){try{if(typeof v==='string')return v;if(typeof v==='function')return '[Function]';return JSON.stringify(v);}catch(e){return String(v);}}"
  "function inherits(c,s){c.super_=s;c.prototype=Object.create(s.prototype,{constructor:{value:c,enumerable:false}});}"
  "function format(f){var a=arguments,i=1;if(typeof f!=='string'){var o=[];for(var k=0;k<a.length;k++)o.push(inspect(a[k]));return o.join(' ');}"
  "var s=String(f).replace(/%[sdjifoO%]/g,function(m){if(m==='%%')return '%';if(i>=a.length)return m;var v=a[i++];if(m==='%d'||m==='%i')return String(parseInt(v));if(m==='%f')return String(parseFloat(v));if(m==='%j')return JSON.stringify(v);if(m==='%s')return String(v);return inspect(v);});"
  "for(;i<a.length;i++)s+=' '+inspect(a[i]);return s;}"
  "function promisify(fn){return function(){var a=Array.prototype.slice.call(arguments),s=this;return new Promise(function(res,rej){a.push(function(e,r){if(e)rej(e);else res(r);});fn.apply(s,a);});};}"
  "def('util',{inherits:inherits,format:format,inspect:inspect,promisify:promisify,deprecate:function(f){return f;},debuglog:function(){return function(){};},"
  "types:{isDate:function(x){return x instanceof Date;},isRegExp:function(x){return x instanceof RegExp;},isNativeError:function(x){return x instanceof Error;}},"
  "isArray:Array.isArray,isBuffer:function(x){return globalThis.Buffer&&Buffer.isBuffer(x);},TextEncoder:globalThis.TextEncoder,TextDecoder:globalThis.TextDecoder});"
  /* path (posix) */
  "var path={sep:'/',delimiter:':'};"
  "path.normalize=function(p){p=String(p);var abs=p.charAt(0)==='/';var parts=p.split('/'),out=[];for(var i=0;i<parts.length;i++){var s=parts[i];if(s===''||s==='.')continue;if(s==='..'){if(out.length&&out[out.length-1]!=='..')out.pop();else if(!abs)out.push('..');}else out.push(s);}var r=out.join('/');if(abs)r='/'+r;if(!r)r=abs?'/':'.';if(p.charAt(p.length-1)==='/'&&r.charAt(r.length-1)!=='/')r+='/';return r;};"
  "path.join=function(){var p=Array.prototype.filter.call(arguments,function(x){return x&&typeof x==='string';}).join('/');return p?path.normalize(p):'.';};"
  "path.isAbsolute=function(p){return String(p).charAt(0)==='/';};"
  "path.resolve=function(){var r='';for(var i=arguments.length-1;i>=-1;i--){var s=i>=0?arguments[i]:'/work';if(!s)continue;r=s+'/'+r;if(path.isAbsolute(s))break;}r=path.normalize(r);return r.length>1&&r.charAt(r.length-1)==='/'?r.slice(0,-1):(r||'/');};"
  "path.dirname=function(p){p=String(p);var i=p.lastIndexOf('/');if(i<0)return '.';if(i===0)return '/';return p.slice(0,i);};"
  "path.basename=function(p,e){p=String(p);var i=p.lastIndexOf('/');var b=i<0?p:p.slice(i+1);if(e&&b.length>=e.length&&b.slice(-e.length)===e)b=b.slice(0,-e.length);return b;};"
  "path.extname=function(p){p=path.basename(p);var i=p.lastIndexOf('.');return i<=0?'':p.slice(i);};"
  "path.parse=function(p){var d=path.dirname(p),b=path.basename(p),e=path.extname(p);return {root:path.isAbsolute(p)?'/':'',dir:d,base:b,ext:e,name:e?b.slice(0,-e.length):b};};"
  "path.format=function(o){var d=o.dir||o.root||'';var b=o.base||((o.name||'')+(o.ext||''));return d?(d+(d.charAt(d.length-1)==='/'?'':'/')+b):b;};"
  "path.relative=function(f,t){var a=path.resolve(f).split('/'),b=path.resolve(t).split('/');var i=0;while(i<a.length&&i<b.length&&a[i]===b[i])i++;var up=[];for(var j=i;j<a.length;j++)up.push('..');return up.concat(b.slice(i)).join('/')||'.';};"
  "path.posix=path;def('path',path);"
  /* buffer */
  "var B64='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';"
  "function b64enc(u){var r='',i;for(i=0;i+2<u.length;i+=3){var n=(u[i]<<16)|(u[i+1]<<8)|u[i+2];r+=B64[n>>18&63]+B64[n>>12&63]+B64[n>>6&63]+B64[n&63];}var rem=u.length-i;if(rem===1){var n=u[i]<<16;r+=B64[n>>18&63]+B64[n>>12&63]+'==';}else if(rem===2){var n=(u[i]<<16)|(u[i+1]<<8);r+=B64[n>>18&63]+B64[n>>12&63]+B64[n>>6&63]+'=';}return r;}"
  "function b64dec(s){s=String(s).replace(/[^A-Za-z0-9+\\/]/g,'');var out=[],i;for(i=0;i+3<s.length;i+=4){var n=(B64.indexOf(s[i])<<18)|(B64.indexOf(s[i+1])<<12)|(B64.indexOf(s[i+2])<<6)|B64.indexOf(s[i+3]);out.push(n>>16&255,n>>8&255,n&255);}var rem=s.length-i;if(rem===2){var n=(B64.indexOf(s[i])<<18)|(B64.indexOf(s[i+1])<<12);out.push(n>>16&255);}else if(rem===3){var n=(B64.indexOf(s[i])<<18)|(B64.indexOf(s[i+1])<<12)|(B64.indexOf(s[i+2])<<6);out.push(n>>16&255,n>>8&255);}return out;}"
  "function strToBytes(s,e){e=e||'utf8';s=String(s);if(e==='hex'){var a=[];for(var i=0;i<s.length;i+=2)a.push(parseInt(s.substr(i,2),16));return a;}if(e==='base64')return b64dec(s);if(e==='latin1'||e==='binary'||e==='ascii'){var a=[];for(var i=0;i<s.length;i++)a.push(s.charCodeAt(i)&255);return a;}return Array.prototype.slice.call(new TextEncoder().encode(s));}"
  "class NodeBuffer extends Uint8Array{"
  "toString(enc,start,end){enc=enc||'utf8';var u=this.subarray(start||0,end===undefined?this.length:end);"
  "if(enc==='hex'){var s='';for(var i=0;i<u.length;i++)s+=(u[i]<16?'0':'')+u[i].toString(16);return s;}"
  "if(enc==='base64')return b64enc(u);"
  "if(enc==='latin1'||enc==='binary'||enc==='ascii'){var s='';for(var i=0;i<u.length;i++)s+=String.fromCharCode(enc==='ascii'?u[i]&127:u[i]);return s;}"
  "return new TextDecoder().decode(u);}"
  "slice(s,e){return new NodeBuffer(this.subarray(s,e));}"
  "equals(o){if(this.length!==o.length)return false;for(var i=0;i<this.length;i++)if(this[i]!==o[i])return false;return true;}"
  "write(str,off,len,enc){if(typeof off==='string'){enc=off;off=0;}off=off||0;var b=strToBytes(str,enc||'utf8');var n=0;for(var i=0;i<b.length&&off+i<this.length;i++){this[off+i]=b[i];n++;}return n;}"
  "toJSON(){return {type:'Buffer',data:Array.prototype.slice.call(this)};}}"
  "function Buffer(a,e){return Buffer.from(a,e);}"
  "Buffer.from=function(a,e){if(typeof a==='string'){var b=strToBytes(a,e);var buf=new NodeBuffer(b.length);buf.set(b);return buf;}if(a instanceof Uint8Array||Array.isArray(a)){var buf=new NodeBuffer(a.length);buf.set(a);return buf;}if(a&&a.buffer){var u=new Uint8Array(a.buffer,a.byteOffset||0,a.byteLength);var buf=new NodeBuffer(u.length);buf.set(u);return buf;}return new NodeBuffer(0);};"
  "Buffer.alloc=function(n,fill){var b=new NodeBuffer(n);if(fill!==undefined&&fill!==0){if(typeof fill==='number')b.fill(fill);else{var f=strToBytes(String(fill));for(var i=0;i<n;i++)b[i]=f[i%f.length];}}return b;};"
  "Buffer.allocUnsafe=function(n){return new NodeBuffer(n);};Buffer.isBuffer=function(b){return b instanceof NodeBuffer;};"
  "Buffer.byteLength=function(s,e){return (s instanceof Uint8Array)?s.length:strToBytes(s,e).length;};"
  "Buffer.concat=function(list,tot){var len=0;list.forEach(function(b){len+=b.length;});if(tot===undefined)tot=len;var out=new NodeBuffer(tot),off=0;list.forEach(function(b){if(off>=tot)return;out.set(b.subarray(0,tot-off),off);off+=b.length;});return out;};"
  "Buffer.isEncoding=function(e){return ['utf8','utf-8','hex','base64','latin1','binary','ascii'].indexOf(String(e).toLowerCase())>-1;};"
  "globalThis.Buffer=Buffer;def('buffer',{Buffer:Buffer,kMaxLength:0x7fffffff});"
  /* os / assert / querystring */
  "def('os',{platform:function(){return 'linux';},arch:function(){return 'wasm32';},type:function(){return 'wasi';},release:function(){return '1.0.0';},"
  "hostname:function(){return 'wasm';},EOL:'\\n',cpus:function(){return [];},totalmem:function(){return 0;},freemem:function(){return 0;},"
  "tmpdir:function(){return '/tmp';},homedir:function(){return '/work';},endianness:function(){return 'LE';},uptime:function(){return 0;},loadavg:function(){return [0,0,0];}});"
  "function AssertionError(m){var e=new Error(m||'assertion failed');e.name='AssertionError';return e;}"
  "function assert(v,m){if(!v)throw AssertionError(m);}"
  "assert.ok=assert;assert.equal=function(a,b,m){if(a!=b)throw AssertionError(m||a+' != '+b);};"
  "assert.strictEqual=function(a,b,m){if(a!==b)throw AssertionError(m||a+' !== '+b);};"
  "assert.notEqual=function(a,b,m){if(a==b)throw AssertionError(m);};"
  "assert.deepEqual=function(a,b,m){if(JSON.stringify(a)!==JSON.stringify(b))throw AssertionError(m||'not deep equal');};"
  "assert.deepStrictEqual=assert.deepEqual;assert.fail=function(m){throw AssertionError(m||'failed');};"
  "assert.throws=function(fn,m){var t=false;try{fn();}catch(e){t=true;}if(!t)throw AssertionError(m||'did not throw');};def('assert',assert);"
  "def('querystring',{parse:function(s){var o={};String(s||'').split('&').forEach(function(p){if(!p)return;var i=p.indexOf('=');var k=i<0?p:p.slice(0,i),v=i<0?'':p.slice(i+1);o[decodeURIComponent(k)]=decodeURIComponent(v);});return o;},"
  "stringify:function(o){return Object.keys(o||{}).map(function(k){return encodeURIComponent(k)+'='+encodeURIComponent(o[k]);}).join('&');}});"
  /* require + module/exports globals */
  "globalThis.require=function(n){n=String(n).replace(/^node:/,'');if(M[n])return M[n];throw new Error(\"Cannot find module '\"+n+\"'\");};"
  "globalThis.require.resolve=function(n){return n;};"
  "globalThis.module={exports:{}};globalThis.exports=globalThis.module.exports;"
  "})();";

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
