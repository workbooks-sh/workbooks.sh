/* Node 'fs' / 'fs/promises' shim — StarlingMonkey eval lane (wb-b9xv, headless-JS path).
 *
 * The Javy-bound shims/fs.js is DEAD on StarlingMonkey (no `Javy.VFS`). SM's only seam back to the host
 * is a guest `fetch()`, so this shim routes every fs op over fetch() to the SAME 127.0.0.1 loopback
 * sentinel the streaming child_process uses — a host fs broker endpoint `POST /__wb/fs`, gated by the
 * per-run grant token (`x-wb-exec`) and CONFINED to the grant's workdir (no arbitrary host FS; the host
 * resolves every path inside the workdir and refuses any escape). One token, one pinned host, one route,
 * verb-dispatched: read / write / append / stat / readdir / mkdir / exists / unlink.
 *
 * SEMANTIC ADJUSTMENT vs Node / the Javy lane (identical to the SM-lane child_process precedent):
 * SpiderMonkey cannot block synchronously on an async fetch, so the `*Sync` variants here resolve to a
 * Promise (await it). The host seam + workdir confinement are otherwise exactly Node's contract; text
 * round-trips cleanly, binary goes through a base64 boundary so bytes survive the JSON hop. The boot seam
 * (`globalThis.__wbExec` = { url, token }) supplies the sentinel URL + grant token; absent => fs disabled.
 */
"use strict";

// __wbExec is injected by the node prelude when a grant is present: { url, token }. Absent => fs disabled.
function cfg() {
  var c = (typeof globalThis !== "undefined" && globalThis.__wbExec) || null;
  if (!c || !c.url) throw new Error("fs: filesystem capability unavailable (no grant on this run)");
  return c;
}

// Derive the fs route from the exec sentinel base (…/__wb/exec → …/__wb/fs).
function fsUrl() { return cfg().url.replace(/\/__wb\/exec$/, "/__wb/fs"); }
function hdr() { return { "content-type": "application/json", "x-wb-exec": cfg().token }; }

function enoent(path) {
  var e = new Error("ENOENT: no such file or directory, open '" + path + "'");
  e.code = "ENOENT"; e.errno = -2; e.path = path;
  return e;
}
function eacces(path, reason) {
  var e = new Error("EACCES: " + (reason || "permission denied") + ", '" + path + "'");
  e.code = "EACCES"; e.errno = -13; e.path = path;
  return e;
}

// b64 <-> Uint8Array (the binary boundary across the JSON hop).
function b64encode(u8) {
  var bin = "";
  for (var i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
  return btoa(bin);
}
function b64decode(s) {
  var bin = atob(s), u = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
  return u;
}

// Marshal arbitrary fs write data (string | Buffer | Uint8Array | ArrayBuffer) to bytes.
function toBytes(data) {
  if (data instanceof Uint8Array) return data;
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (data && data.buffer instanceof ArrayBuffer) return new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength);
  return new TextEncoder().encode(String(data));
}

// One verb over the loopback. body {op, path, ...}. Resolves to the parsed JSON, or throws a mapped error.
function op(body) {
  var c = cfg();
  return fetch(fsUrl(), { method: "POST", headers: hdr(), body: JSON.stringify(body) })
    .then(function (res) {
      return res.text().then(function (txt) {
        var j = null; try { j = txt ? JSON.parse(txt) : null; } catch (_) {}
        if (res.status === 404) throw enoent(body.path);
        if (res.status === 403) throw eacces(body.path, (j && j.error) || "fs op denied / outside workdir");
        if (!res.ok) { var e = new Error("EIO: fs op failed (" + res.status + ") for '" + body.path + "'"); e.code = "EIO"; throw e; }
        return j || {};
      });
    });
}

// ── sync surface (returns a Promise on SM — await it) ─────────────────────────────────────────

function readFileSync(path, opts) {
  var enc = typeof opts === "string" ? opts : opts && opts.encoding;
  return op({ op: "read", path: String(path) }).then(function (j) {
    var bytes = b64decode(j.data || "");
    if (enc) return new TextDecoder().decode(bytes); // utf8 (& friends) → string
    return bytes;                                     // no encoding → bytes
  });
}

function writeFileSync(path, data) {
  return op({ op: "write", path: String(path), data: b64encode(toBytes(data)) }).then(function () {});
}

function appendFileSync(path, data) {
  return op({ op: "append", path: String(path), data: b64encode(toBytes(data)) }).then(function () {});
}

function existsSync(path) {
  return op({ op: "exists", path: String(path) }).then(function (j) { return !!j.exists; });
}

function statSync(path) {
  return op({ op: "stat", path: String(path) }).then(function (j) {
    var isDir = !!j.is_dir;
    return {
      size: j.size || 0,
      isFile: function () { return !isDir; },
      isDirectory: function () { return isDir; },
      isSymbolicLink: function () { return false; },
      mtimeMs: j.mtime_ms || 0, ctimeMs: j.mtime_ms || 0
    };
  });
}

function mkdirSync(path, opts) {
  var recursive = !!(opts && (opts === true || opts.recursive));
  return op({ op: "mkdir", path: String(path), recursive: recursive }).then(function () {});
}

function readdirSync(path) {
  return op({ op: "readdir", path: String(path) }).then(function (j) { return j.entries || []; });
}

function unlinkSync(path) {
  return op({ op: "unlink", path: String(path) }).then(function () {});
}

function rmSync(path, opts) {
  var recursive = !!(opts && opts.recursive);
  return op({ op: "unlink", path: String(path), recursive: recursive }).then(function () {});
}

// ── fs/promises surface ───────────────────────────────────────────────────────────────────────
// These are already promise-returning; the *Sync funcs return promises on SM, so promises just alias them.
var promises = {
  readFile: function (p, o) { return readFileSync(p, o); },
  writeFile: function (p, d) { return writeFileSync(p, d); },
  appendFile: function (p, d) { return appendFileSync(p, d); },
  stat: function (p) { return statSync(p); },
  mkdir: function (p, o) { return mkdirSync(p, o); },
  readdir: function (p) { return readdirSync(p); },
  unlink: function (p) { return unlinkSync(p); },
  rm: function (p, o) { return rmSync(p, o); },
  access: function (p) { return existsSync(p).then(function (ex) { if (!ex) throw enoent(p); }); }
};

module.exports = {
  readFileSync: readFileSync, writeFileSync: writeFileSync, appendFileSync: appendFileSync,
  existsSync: existsSync, statSync: statSync, mkdirSync: mkdirSync, readdirSync: readdirSync,
  unlinkSync: unlinkSync, rmSync: rmSync,
  promises: promises
};
