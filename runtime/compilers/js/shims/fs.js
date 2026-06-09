/* Node 'fs' shim (wb-e1x.3 / JD.3) — backed by Javy.VFS (host_vfs_read/write) via JsDock. Only
 * works in the :dock lane (a command linked against harness_dock + run under Workbooks.JsDock);
 * on the plain CLI lane Javy.VFS is undefined. The VFS is a sandboxed KV store (path → bytes),
 * so directories are virtual: mkdir is a no-op and readdir returns []. Text round-trips cleanly;
 * binary goes through a UTF-8 string boundary (host_vfs_* marshal JS strings). No host FS reach. */
"use strict";

function vfs() {
  if (typeof Javy === "undefined" || !Javy.VFS) {
    throw new Error("fs: VFS capability unavailable — this command must run in the JsDock lane");
  }
  return Javy.VFS;
}

function enoent(path) {
  var e = new Error("ENOENT: no such file or directory, open '" + path + "'");
  e.code = "ENOENT";
  e.errno = -2;
  e.path = path;
  return e;
}

function readFileSync(path, opts) {
  var s = vfs().read(String(path));
  if (s === null) throw enoent(path);
  var enc = typeof opts === "string" ? opts : opts && opts.encoding;
  if (enc) return s; // utf8 (and friends) → string
  return new TextEncoder().encode(s); // no encoding → Buffer-like bytes
}

function toStr(data) {
  if (typeof data === "string") return data;
  if (data instanceof Uint8Array) return new TextDecoder().decode(data);
  if (data && data.buffer) return new TextDecoder().decode(new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength));
  return String(data);
}

function writeFileSync(path, data) {
  if (!vfs().write(String(path), toStr(data))) throw new Error("EIO: fs write failed for '" + path + "'");
}

function appendFileSync(path, data) {
  var prev = vfs().read(String(path));
  writeFileSync(path, (prev === null ? "" : prev) + toStr(data));
}

function existsSync(path) {
  return vfs().read(String(path)) !== null;
}

function statSync(path) {
  var s = vfs().read(String(path));
  if (s === null) throw enoent(path);
  var size = new TextEncoder().encode(s).length;
  return {
    size: size,
    isFile: function () { return true; },
    isDirectory: function () { return false; },
    isSymbolicLink: function () { return false; },
    mtimeMs: 0, ctimeMs: 0
  };
}

function mkdirSync() {}        // KV VFS has no real directories
function readdirSync() { return []; }

var promises = {
  readFile: function (p, o) { return Promise.resolve().then(function () { return readFileSync(p, o); }); },
  writeFile: function (p, d) { return Promise.resolve().then(function () { return writeFileSync(p, d); }); },
  appendFile: function (p, d) { return Promise.resolve().then(function () { return appendFileSync(p, d); }); },
  stat: function (p) { return Promise.resolve().then(function () { return statSync(p); }); }
};

module.exports = {
  readFileSync: readFileSync, writeFileSync: writeFileSync, appendFileSync: appendFileSync,
  existsSync: existsSync, statSync: statSync, mkdirSync: mkdirSync, readdirSync: readdirSync,
  promises: promises
};
