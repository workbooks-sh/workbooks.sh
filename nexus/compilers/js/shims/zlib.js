/* Node 'zlib' shim — API-presence only. Many packages `require('zlib')` at load but never compress on
 * the hot path; this lets them load. Actual (de)compression needs a real DEFLATE codec we don't bundle
 * here yet — those calls throw a clear error rather than silently corrupting data. If a package needs
 * real gzip in-sandbox, install a pure-JS codec (e.g. pako) via npm; it bundles and runs unchanged.
 * (Documented frontier.) */
"use strict";
function unsupported(name) {
  return function () { throw new Error("zlib." + name + " is not available in the in-sandbox JS lane — install a pure-JS codec (e.g. pako) instead"); };
}
var sync = ["deflateSync", "inflateSync", "gzipSync", "gunzipSync", "deflateRawSync", "inflateRawSync", "brotliCompressSync", "brotliDecompressSync", "unzipSync"];
var asyncFns = ["deflate", "inflate", "gzip", "gunzip", "deflateRaw", "inflateRaw", "brotliCompress", "brotliDecompress", "unzip"];
var m = {};
sync.forEach(function (n) { m[n] = unsupported(n); });
asyncFns.forEach(function (n) {
  m[n] = function (buf, opts, cb) { cb = typeof opts === "function" ? opts : cb; if (cb) cb(new Error("zlib." + n + " not available in-sandbox")); };
});
m.constants = {};
m.createGzip = m.createGunzip = m.createDeflate = m.createInflate = function () {
  throw new Error("zlib streams are not available in the in-sandbox JS lane — install a pure-JS codec (e.g. pako)");
};
module.exports = m;
