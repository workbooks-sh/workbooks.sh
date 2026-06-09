/* Node 'buffer' shim (wb-spy.T2.1) — a real-ish Buffer over Uint8Array, pure JS. Supports
 * utf8/hex/base64 + from/alloc/concat/isBuffer/byteLength/slice/equals/toString. No caps. */
"use strict";
var B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

function fromUtf8(s) { return new TextEncoder().encode(s); }
function toUtf8(u) { return new TextDecoder().decode(u); }

function fromHex(s) {
  s = String(s).replace(/[^0-9a-fA-F]/g, "");
  var n = s.length >> 1, u = new Uint8Array(n);
  for (var i = 0; i < n; i++) u[i] = parseInt(s.substr(i * 2, 2), 16);
  return u;
}
function toHex(u) {
  var s = "";
  for (var i = 0; i < u.length; i++) s += (u[i] < 16 ? "0" : "") + u[i].toString(16);
  return s;
}
function fromB64(s) {
  s = String(s).replace(/[^A-Za-z0-9+/]/g, "");
  var out = [], i = 0;
  while (i < s.length) {
    var e1 = B64.indexOf(s[i++]), e2 = B64.indexOf(s[i++]),
      e3 = B64.indexOf(s[i++]), e4 = B64.indexOf(s[i++]);
    var c1 = (e1 << 2) | (e2 >> 4); out.push(c1);
    if (e3 >= 0) out.push(((e2 & 15) << 4) | (e3 >> 2));
    if (e4 >= 0) out.push(((e3 & 3) << 6) | e4);
  }
  return new Uint8Array(out);
}
function toB64(u) {
  var s = "", i;
  for (i = 0; i + 2 < u.length; i += 3) {
    var n = (u[i] << 16) | (u[i + 1] << 8) | u[i + 2];
    s += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63];
  }
  var rem = u.length - i;
  if (rem === 1) { var a = u[i] << 16; s += B64[(a >> 18) & 63] + B64[(a >> 12) & 63] + "=="; }
  else if (rem === 2) { var b = (u[i] << 16) | (u[i + 1] << 8); s += B64[(b >> 18) & 63] + B64[(b >> 12) & 63] + B64[(b >> 6) & 63] + "="; }
  return s;
}

function decode(s, enc) {
  enc = (enc || "utf8").toLowerCase();
  if (enc === "hex") return fromHex(s);
  if (enc === "base64") return fromB64(s);
  return fromUtf8(s);
}

function make(u) {
  u.__isBuffer = true;
  u.toString = function (enc) {
    enc = (enc || "utf8").toLowerCase();
    if (enc === "hex") return toHex(this);
    if (enc === "base64") return toB64(this);
    return toUtf8(this);
  };
  u.equals = function (o) {
    if (this.length !== o.length) return false;
    for (var i = 0; i < this.length; i++) if (this[i] !== o[i]) return false;
    return true;
  };
  var origSlice = u.slice.bind(u);
  u.slice = function (a, b) { return make(new Uint8Array(origSlice(a, b))); };
  return u;
}

var Buffer = {
  from: function (v, enc) {
    if (typeof v === "string") return make(decode(v, enc));
    if (v instanceof Uint8Array || Array.isArray(v)) return make(new Uint8Array(v));
    if (v && v.buffer) return make(new Uint8Array(v.buffer, v.byteOffset || 0, v.byteLength));
    return make(new Uint8Array(0));
  },
  alloc: function (n, fill) {
    var u = new Uint8Array(n);
    if (fill != null) u.fill(typeof fill === "number" ? fill : fill.charCodeAt(0));
    return make(u);
  },
  allocUnsafe: function (n) { return make(new Uint8Array(n)); },
  isBuffer: function (x) { return !!(x && (x.__isBuffer || x instanceof Uint8Array)); },
  byteLength: function (s, enc) { return decode(String(s), enc).length; },
  concat: function (list, total) {
    var len = total != null ? total : list.reduce(function (a, b) { return a + b.length; }, 0);
    var out = new Uint8Array(len), o = 0;
    for (var i = 0; i < list.length && o < len; i++) {
      var c = list[i];
      for (var j = 0; j < c.length && o < len; j++) out[o++] = c[j];
    }
    return make(out);
  }
};
module.exports = { Buffer: Buffer };
