/* Node 'string_decoder' shim (wb-spy.T2.1) — UTF-8 StringDecoder over TextDecoder, pure JS.
 * Buffers incomplete multibyte sequences across write() calls. */
"use strict";
function StringDecoder(enc) { this.encoding = (enc || "utf8").toLowerCase(); this._buf = new Uint8Array(0); }
function concat(a, b) { var u = new Uint8Array(a.length + b.length); u.set(a, 0); u.set(b, a.length); return u; }
// How many trailing bytes form an incomplete UTF-8 sequence (0..3).
function incomplete(u) {
  var n = u.length;
  for (var back = 1; back <= 3 && back <= n; back++) {
    var c = u[n - back];
    if (c < 0x80) return 0;            // ascii: complete
    if (c >= 0xc0) {                   // lead byte: need (len) bytes total
      var need = c >= 0xf0 ? 4 : c >= 0xe0 ? 3 : 2;
      return back < need ? back : 0;
    }
  }
  return 0;                            // all continuation bytes within window
}
StringDecoder.prototype.write = function (chunk) {
  var u = chunk instanceof Uint8Array ? chunk : new Uint8Array(chunk);
  var all = this._buf.length ? concat(this._buf, u) : u;
  var hold = incomplete(all);
  var ready = hold ? all.subarray(0, all.length - hold) : all;
  this._buf = hold ? new Uint8Array(all.subarray(all.length - hold)) : new Uint8Array(0);
  return new TextDecoder().decode(ready);
};
StringDecoder.prototype.end = function (chunk) {
  var s = chunk ? this.write(chunk) : "";
  if (this._buf.length) { s += new TextDecoder().decode(this._buf); this._buf = new Uint8Array(0); }
  return s;
};
module.exports = { StringDecoder: StringDecoder };
