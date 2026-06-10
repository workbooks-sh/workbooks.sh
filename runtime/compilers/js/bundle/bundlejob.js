/* wb in-sandbox JS bundler (wb-spy.T1.4). Runs inside qjs-run.wasm — same IO contract as
 * ts/tsjob.js (Javy.IO stdin→stdout), ZERO native execution, no esbuild/rollup/node.
 *
 * stdin  : JSON {"entry": "<relpath>", "files": {"<relpath>": "<source>", ...}}
 *          `files` is the project's entry + the assembled node_modules/ tree (.js/.cjs/.mjs/.json),
 *          paths POSIX-relative to the project root (supplied by Workbooks.Compilers.bundle_dir).
 * stdout : a single self-contained CommonJS bundle (a tiny module registry + the entry executed).
 *
 * Resolution: relative requests (./ ../) resolve against the requester's dir with the usual
 * extension/index/package.json("main") probing; bare requests resolve in the FLAT (hoisted)
 * node_modules/ produced by T1.3. require() is fully supported; a minimal ESM→CJS transform
 * covers the common import/export forms so simple ESM packages bundle too. */

function readStdin() {
  var chunks = [], total = 0, CH = 1 << 20;
  for (;;) {
    var b = new Uint8Array(CH);
    var n = Javy.IO.readSync(0, b);
    if (n <= 0) break;
    chunks.push(b.subarray(0, n));
    total += n;
  }
  var out = new Uint8Array(total), o = 0;
  for (var i = 0; i < chunks.length; i++) { out.set(chunks[i], o); o += chunks[i].length; }
  return new TextDecoder().decode(out);
}

function write(s) { Javy.IO.writeSync(1, new TextEncoder().encode(s)); }
function die(msg) { Javy.IO.writeSync(2, new TextEncoder().encode("BUNDLE ERR: " + msg + "\n")); }

var DIR = function (p) { var i = p.lastIndexOf("/"); return i < 0 ? "" : p.slice(0, i); };

function joinPath(base, rel) {
  var parts = (base ? base.split("/") : []);
  var segs = rel.split("/");
  for (var i = 0; i < segs.length; i++) {
    var s = segs[i];
    if (s === "" || s === ".") continue;
    if (s === "..") parts.pop();
    else parts.push(s);
  }
  return parts.join("/");
}

var EXTS = ["", ".js", ".cjs", ".mjs", ".json"];

// Resolve a file path against the files map, trying extensions, /index, and package.json main.
function resolveFile(files, p) {
  for (var i = 0; i < EXTS.length; i++) if (files[p + EXTS[i]] != null) return p + EXTS[i];
  // directory: package.json "main", then index.*
  var pj = p + "/package.json";
  if (files[pj] != null) {
    try {
      var main = (JSON.parse(files[pj]).main) || "index.js";
      var m = joinPath(p, main);
      for (var j = 0; j < EXTS.length; j++) if (files[m + EXTS[j]] != null) return m + EXTS[j];
      var mi = joinPath(m, "index");
      for (var k = 0; k < EXTS.length; k++) if (files[mi + EXTS[k]] != null) return mi + EXTS[k];
    } catch (e) {}
  }
  var idx = p + "/index";
  for (var x = 0; x < EXTS.length; x++) if (files[idx + EXTS[x]] != null) return idx + EXTS[x];
  return null;
}

// Node core builtins we shim in-sandbox (wb-spy.T2.5) — injected by Elixir as __shims__/<name>.js.
var SHIM = { assert: 1, buffer: 1, crypto: 1, events: 1, path: 1, process: 1, querystring: 1, string_decoder: 1, timers: 1, url: 1, util: 1 };
// Builtins available ONLY in the JsDock lane (wb-e1x): host-brokered fs/http/https shims backed
// by Javy.VFS / Javy.Net. Permitted when the bundle is dock-targeted (input.dock); otherwise they
// fall through to NATIVE and are build-rejected (the plain CLI lane has no host caps).
var DOCKSHIM = { fs: 1, http: 1, https: 1 };
// Builtins that need native OS/threads/raw sockets — not available in any lane → build-time reject.
var NATIVE = {
  fs: "needs the JsDock lane (host VFS) — not available on the plain CLI lane",
  net: "raw TCP sockets are not available in-sandbox",
  http: "needs the JsDock lane (host-brokered fetch) — not available on the plain CLI lane",
  https: "needs the JsDock lane (host-brokered fetch) — not available on the plain CLI lane",
  http2: "no native network", tls: "no native TLS sockets", dgram: "no UDP", dns: "no resolver",
  child_process: "no subprocesses in-sandbox", worker_threads: "no threads", cluster: "no clustering",
  vm: "no nested VM", v8: "no V8 internals", inspector: "no inspector", repl: "no repl",
  readline: "no TTY", os: "not shimmed yet", stream: "not shimmed yet", zlib: "not shimmed yet"
};

function resolveBare(files, req) {
  // flat node_modules. "ms" -> node_modules/ms ; "ms/foo" -> node_modules/ms/foo ;
  // "@scope/pkg/sub" keeps the scope+name as the package root.
  var seg = req.split("/");
  var pkg = req[0] === "@" ? seg.slice(0, 2).join("/") : seg[0];
  var sub = req.slice(pkg.length).replace(/^\//, "");
  var root = "node_modules/" + pkg;
  return resolveFile(files, sub ? joinPath(root, sub) : root);
}

function resolve(files, from, req) {
  if (req[0] === ".") return resolveFile(files, joinPath(DIR(from), req));

  var forced = req.indexOf("node:") === 0;          // node:foo always means the builtin
  var bare = forced ? req.slice(5) : req;
  var top = bare.split("/")[0];

  if (SHIM[top] || NATIVE[top]) {
    // A node_modules polyfill (an installed package of the same name) wins for a BARE name; a
    // node:-scheme request always binds the builtin shim.
    if (!forced) { var poly = resolveBare(files, req); if (poly) return poly; }
    if (SHIM[top] && !bare.includes("/")) return "__shims__/" + top + ".js";
    // Dock-targeted bundles get the host-brokered fs/http/https shims (run via JsDock).
    if (DOCK_OK && DOCKSHIM[top] && !bare.includes("/")) return "__shims__/" + top + ".js";
    throw "Unsupported Node builtin '" + bare + "' — " + (NATIVE[top] || "not available in the in-sandbox JS lane");
  }

  return resolveBare(files, req);
}

// Minimal ESM→CJS transform for the common forms (only applied to .mjs or sources that use
// import/export). Good enough for simple packages; complex ESM is the documented frontier.
function esmToCjs(src) {
  if (!/\b(import|export)\b/.test(src)) return src;
  var s = src;
  s = s.replace(/import\s+\*\s+as\s+(\w+)\s+from\s+["']([^"']+)["'];?/g, "const $1 = require(\"$2\");");
  s = s.replace(/import\s+(\w+)\s*,\s*\{([^}]*)\}\s+from\s+["']([^"']+)["'];?/g,
    "const __d = require(\"$3\"); const $1 = __d && __d.__esModule ? __d.default : __d; const {$2} = __d;");
  s = s.replace(/import\s+\{([^}]*)\}\s+from\s+["']([^"']+)["'];?/g, "const {$1} = require(\"$2\");");
  s = s.replace(/import\s+(\w+)\s+from\s+["']([^"']+)["'];?/g,
    "const __m = require(\"$2\"); const $1 = __m && __m.__esModule ? __m.default : __m;");
  s = s.replace(/import\s+["']([^"']+)["'];?/g, "require(\"$1\");");
  s = s.replace(/export\s+default\s+/g, "module.exports.default = module.exports.__esModule = true, module.exports.default = ");
  s = s.replace(/export\s+(const|let|var|function|class)\s+(\w+)/g, "$1 $2; module.exports.$2 = $2; $1 $2".replace(/.*/, "$1 $2"));
  s = s.replace(/export\s+\{([^}]*)\};?/g, function (_, names) {
    return names.split(",").map(function (n) {
      var parts = n.trim().split(/\s+as\s+/); var local = parts[0].trim(); var ext = (parts[1] || local).trim();
      return local ? ("module.exports." + ext + " = " + local + ";") : "";
    }).join(" ");
  });
  return s;
}

// Scan a module body for require("x") targets (post-ESM-transform, so import is already require).
function scanRequires(src) {
  var out = [], re = /require\(\s*["']([^"']+)["']\s*\)/g, m;
  while ((m = re.exec(src)) !== null) out.push(m[1]);
  return out;
}

function bundle(input) {
  var entry = resolveFile(input.files, input.entry);
  if (!entry) throw "cannot resolve entry: " + input.entry;
  var files = input.files;
  var mods = {}, deps = {}, queue = [entry], seen = {};

  while (queue.length) {
    var p = queue.shift();
    if (seen[p]) continue;
    seen[p] = true;

    if (/\.json$/.test(p)) {
      mods[p] = "module.exports = " + files[p] + ";";
      deps[p] = {};
      continue;
    }

    var src = esmToCjs(files[p]);
    mods[p] = src;
    deps[p] = {};
    var reqs = scanRequires(src);
    for (var i = 0; i < reqs.length; i++) {
      var r = reqs[i];
      var t = resolve(files, p, r);
      if (t) { deps[p][r] = t; if (!seen[t]) queue.push(t); }
      // unresolved (e.g. a node builtin not shimmed) is left to fail at runtime with a clear msg
    }
  }

  var parts = [];
  parts.push("(function(){var __m={},__c={};");
  parts.push("var __d=" + JSON.stringify(deps) + ";");
  parts.push("function __require(from){return function(req){var t=__d[from]&&__d[from][req];" +
    "if(!t)throw new Error(\"Cannot find module '\"+req+\"' from '\"+from+\"'\");return __load(t);};}");
  parts.push("function __load(p){if(__c[p])return __c[p].exports;var mod={exports:{}};__c[p]=mod;" +
    "__m[p](mod,mod.exports,__require(p));return mod.exports;}");
  for (var p2 in mods) {
    parts.push("__m[" + JSON.stringify(p2) + "]=function(module,exports,require){\n" + mods[p2] + "\n};");
  }
  parts.push("__load(" + JSON.stringify(entry) + ");");
  parts.push("})();");
  return parts.join("\n");
}

var DOCK_OK = false; // set from input.dock — permits the host-brokered fs/http/https shims

// Helpers a sibling lane reuses (publish them so the sibling doesn't re-implement resolution). This
// runs at load (before the driver below), so they're available when the hook fires.
globalThis.__wbBundle = { resolve: resolve, resolveFile: resolveFile, joinPath: joinPath, DIR: DIR, esmToCjs: esmToCjs, bundle: bundle };

// Single driver for every JS lane. A SIBLING lane (e.g. the Svelte lane, sveltejob.js) is
// concatenated BEFORE this file by the Elixir side and registers a pre-bundle hook on
// globalThis.__wbPreBundle — it rewrites input.files (e.g. .svelte → emitted JS modules) using the
// helpers above before the unchanged bundle() runs. ONE driver + ONE bundle path is the DRY win: a
// lane is "a transform over the file-map", not a forked bundler. The sibling only registers the
// hook; THIS driver (always at the bottom of the concatenated source) reads stdin and runs it.
try {
  var input = JSON.parse(readStdin());
  DOCK_OK = !!input.dock;
  if (typeof globalThis.__wbPreBundle === "function") input = globalThis.__wbPreBundle(input);
  write(bundle(input));
} catch (e) {
  die(e + (e && e.stack ? "\n" + e.stack : ""));
}
