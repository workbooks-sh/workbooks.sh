/* Node-compat prelude for StarlingMonkey (Workbooks.JsEngine, SLICE 0 — wb-b9xv).
 *
 * StarlingMonkey gives us the web-platform half (fetch / WebCrypto / TextEncoder / JSON / modern ES)
 * but NO `process` / `require` / `module` / `Buffer` / `node:` resolver. A Node-shaped bundle dies on
 * line 1 (the probe hit exactly this: "require is not defined"). This prelude — prepended to the
 * evaluated source BEFORE the user script — installs a CommonJS-ish module system + a `node:`/bare
 * resolver backed by an embedded pure-JS shim registry, plus the missing globals.
 *
 * NO Javy.* here (that lane does not exist on SM). fs / child_process are OUT OF SCOPE for SLICE 0
 * (later slices wire host imports). The shims registered are pure JS, no caps.
 *
 * Host injection seam: before this prelude runs, JsEngine sets
 *   globalThis.__wbNode = { shims: { "<name>": "<source>" , ... }, env: {...}, argv: [...] }
 * The prelude consumes __wbNode to (a) populate the shim registry and (b) build a host-injectable
 * `process` (env/argv from Elixir opts; stdout buffered + returned). It then deletes __wbNode.
 */
"use strict";
(function () {
  var boot = globalThis.__wbNode || {};
  var SHIM_SRC = boot.shims || {};

  // ---- stdout/stderr capture (buffered, returned to the host) ----------------------------------
  var __stdout = [];
  var __stderr = [];
  globalThis.__wbStdout = __stdout; // host reads this back after run
  globalThis.__wbStderr = __stderr;

  // ---- console capture --------------------------------------------------------------------------
  // SM has stdio DISABLED, so a Node script's console.log/error would otherwise vanish. Route them
  // into the same buffers process.stdout/stderr use (Node sends log/info/debug→stdout, warn/error→
  // stderr), each call ending in a newline (Node's behaviour). Args are space-joined, objects JSON'd.
  function __fmt(a) {
    return Array.prototype.map.call(a, function (x) {
      if (typeof x === "string") return x;
      try { return typeof x === "object" && x !== null ? JSON.stringify(x) : String(x); }
      catch (_) { return String(x); }
    }).join(" ");
  }
  globalThis.console = {
    log: function () { __stdout.push(__fmt(arguments) + "\n"); },
    info: function () { __stdout.push(__fmt(arguments) + "\n"); },
    debug: function () { __stdout.push(__fmt(arguments) + "\n"); },
    warn: function () { __stderr.push(__fmt(arguments) + "\n"); },
    error: function () { __stderr.push(__fmt(arguments) + "\n"); },
    trace: function () { __stderr.push(__fmt(arguments) + "\n"); }
  };

  // ---- process (host-injectable) ---------------------------------------------------------------
  var process = {
    env: boot.env || {},
    argv: boot.argv || ["node", "script"],
    argv0: "node",
    platform: "wasi",
    arch: "wasm32",
    version: "v18.0.0",
    versions: { node: "18.0.0", v8: "0.0.0" },
    pid: 1,
    ppid: 0,
    title: "node",
    cwd: function () { return (boot.env && boot.env.PWD) || "/"; },
    chdir: function () {},
    nextTick: function (fn) {
      var a = Array.prototype.slice.call(arguments, 1);
      Promise.resolve().then(function () { fn.apply(null, a); });
    },
    hrtime: function (prev) {
      var ns = (typeof performance !== "undefined" && performance.now ? performance.now() : Date.now()) * 1e6;
      var s = Math.floor(ns / 1e9), n = Math.floor(ns % 1e9);
      if (prev) { return [s - prev[0], n - prev[1]]; }
      return [s, n];
    },
    exit: function (code) { process.exitCode = code | 0; },
    exitCode: 0,
    on: function () { return process; },
    once: function () { return process; },
    off: function () { return process; },
    addListener: function () { return process; },
    removeListener: function () { return process; },
    emit: function () { return false; },
    emitWarning: function () {},
    stdout: { write: function (s) { __stdout.push(String(s)); return true; }, isTTY: false, fd: 1 },
    stderr: { write: function (s) { __stderr.push(String(s)); return true; }, isTTY: false, fd: 2 },
    stdin: { read: function () { return null; }, isTTY: false, fd: 0, on: function () { return this; }, resume: function () {}, pause: function () {} }
  };
  process.hrtime.bigint = function () {
    var ns = (typeof performance !== "undefined" && performance.now ? performance.now() : Date.now()) * 1e6;
    return BigInt(Math.floor(ns));
  };

  // ---- Buffer (minimal, over Uint8Array + TextEncoder/Decoder) ----------------------------------
  function Buffer(arg, enc) { return Buffer.from(arg, enc); }
  Buffer.from = function (value, enc) {
    if (value instanceof Uint8Array) { var c = new Uint8Array(value.length); c.set(value); return wrap(c); }
    if (value instanceof ArrayBuffer) { return wrap(new Uint8Array(value)); }
    if (Array.isArray(value)) { return wrap(new Uint8Array(value)); }
    if (typeof value === "string") {
      enc = (enc || "utf8").toLowerCase();
      if (enc === "base64") {
        var bin = atob(value), u = new Uint8Array(bin.length);
        for (var i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
        return wrap(u);
      }
      if (enc === "hex") {
        var h = value, n = h.length >> 1, b = new Uint8Array(n);
        for (var j = 0; j < n; j++) b[j] = parseInt(h.substr(j * 2, 2), 16);
        return wrap(b);
      }
      return wrap(new TextEncoder().encode(value));
    }
    if (typeof value === "number") { return wrap(new Uint8Array(value)); }
    return wrap(new Uint8Array(0));
  };
  Buffer.alloc = function (n, fill) {
    var u = new Uint8Array(n);
    if (fill != null) u.fill(typeof fill === "number" ? fill : (fill.charCodeAt ? fill.charCodeAt(0) : 0));
    return wrap(u);
  };
  Buffer.allocUnsafe = function (n) { return wrap(new Uint8Array(n)); };
  Buffer.isBuffer = function (x) { return !!(x && x.__isBuffer); };
  Buffer.concat = function (list, total) {
    var len = total != null ? total : list.reduce(function (a, b) { return a + b.length; }, 0);
    var out = new Uint8Array(len), off = 0;
    for (var i = 0; i < list.length; i++) { out.set(list[i].subarray ? list[i].subarray(0, len - off) : list[i], off); off += list[i].length; if (off >= len) break; }
    return wrap(out);
  };
  Buffer.byteLength = function (s, enc) { return Buffer.from(s, enc).length; };
  function wrap(u) {
    u.__isBuffer = true;
    u.toString = function (enc) {
      enc = (enc || "utf8").toLowerCase();
      if (enc === "base64") { var s = ""; for (var i = 0; i < this.length; i++) s += String.fromCharCode(this[i]); return btoa(s); }
      if (enc === "hex") { var h = ""; for (var j = 0; j < this.length; j++) h += this[j].toString(16).padStart(2, "0"); return h; }
      return new TextDecoder().decode(this);
    };
    u.toJSON = function () { return { type: "Buffer", data: Array.prototype.slice.call(this) }; };
    u.equals = function (o) { if (this.length !== o.length) return false; for (var i = 0; i < this.length; i++) if (this[i] !== o[i]) return false; return true; };
    u.slice = function (a, b) { return wrap(Uint8Array.prototype.subarray.call(this, a, b)); };
    return u;
  }

  // ---- CommonJS module system + node:/bare resolver --------------------------------------------
  // Registry maps a canonical module id -> { factory(module, exports, require), exports, loaded }.
  // Builtin shims are registered by bare name ("path", "url", ...). A `node:` prefix and relative
  // requires between shims ("./querystring") resolve into the same registry.
  var registry = Object.create(null);

  function canon(id) {
    if (id.indexOf("node:") === 0) id = id.slice(5);
    if (id.indexOf("./") === 0) id = id.slice(2);   // shim-relative -> bare
    if (id.indexOf("/") === 0) id = id.slice(1);
    return id;
  }

  function define(name, source) {
    // Wrap the shim source in a CJS factory. `require`/`module`/`exports`/`process`/`Buffer`/
    // `global`/`globalThis` are in scope so shims load unchanged (they were authored for QuickJS CJS).
    var factory = new Function(
      "require", "module", "exports", "process", "Buffer", "global", "globalThis", "__filename", "__dirname",
      source + "\n//# sourceURL=node:" + name
    );
    registry[canon(name)] = { factory: factory, exports: {}, loaded: false };
  }

  function require(id) {
    var key = canon(id);
    var rec = registry[key];
    if (!rec) throw new Error("Cannot find module '" + id + "' (SLICE 0: only embedded node: builtins resolve)");
    if (rec.loaded) return rec.exports;
    rec.loaded = true; // set before running so cyclic requires get the partial exports
    var module = { exports: rec.exports, id: key };
    rec.factory.call(rec.exports, require, module, module.exports, process, Buffer, globalThis, globalThis, "/" + key + ".js", "/");
    rec.exports = module.exports; // module.exports = X reassignment wins
    return rec.exports;
  }
  require.resolve = function (id) { return canon(id); };
  require.cache = registry;

  // Register every shim the host injected.
  Object.keys(SHIM_SRC).forEach(function (name) { define(name, SHIM_SRC[name]); });

  // `process` is a builtin module too (require('node:process')) AND a global (Node exposes both).
  registry["process"] = { factory: null, exports: process, loaded: true };

  // ---- install globals -------------------------------------------------------------------------
  globalThis.process = process;
  globalThis.Buffer = Buffer;
  globalThis.require = require;
  globalThis.module = { exports: {} };
  globalThis.exports = globalThis.module.exports;
  globalThis.global = globalThis;
  if (typeof globalThis.__filename === "undefined") globalThis.__filename = "/script.js";
  if (typeof globalThis.__dirname === "undefined") globalThis.__dirname = "/";

  // Exec seam (SLICE 1): when the host granted exec, expose { url, token } so the SM-lane child_process
  // shim can fetch() the ExecLoopback sentinel. Absent => the shim throws "exec capability unavailable".
  if (boot.exec) globalThis.__wbExec = boot.exec;

  // timers shim self-installs setTimeout/queueMicrotask globals when required; SM already has them.
  delete globalThis.__wbNode;
})();
