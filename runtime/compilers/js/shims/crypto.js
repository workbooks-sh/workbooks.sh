/* Node 'crypto' shim (wb-spy.T2.4) — pure JS, no caps. createHash (sha256/sha1) + createHmac +
 * randomBytes/randomUUID. NOTE: randomBytes uses Math.random — the sandbox exposes no entropy
 * source, so it is NOT cryptographically secure; fine for ids/nonces, not for keys. */
"use strict";

function bytesOf(data, enc) {
  if (data instanceof Uint8Array) return data;
  if (data && data.buffer) return new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength);
  enc = (enc || "utf8").toLowerCase();
  var s = String(data);
  if (enc === "hex") {
    var n = s.length >> 1, u = new Uint8Array(n);
    for (var i = 0; i < n; i++) u[i] = parseInt(s.substr(i * 2, 2), 16);
    return u;
  }
  return new TextEncoder().encode(s);
}
function toHex(u) { var s = ""; for (var i = 0; i < u.length; i++) s += (u[i] < 16 ? "0" : "") + u[i].toString(16); return s; }
function toB64(u) {
  var B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", s = "", i;
  for (i = 0; i + 2 < u.length; i += 3) { var n = (u[i] << 16) | (u[i + 1] << 8) | u[i + 2]; s += B[(n >> 18) & 63] + B[(n >> 12) & 63] + B[(n >> 6) & 63] + B[n & 63]; }
  var r = u.length - i;
  if (r === 1) { var a = u[i] << 16; s += B[(a >> 18) & 63] + B[(a >> 12) & 63] + "=="; }
  else if (r === 2) { var b = (u[i] << 16) | (u[i + 1] << 8); s += B[(b >> 18) & 63] + B[(b >> 12) & 63] + B[(b >> 6) & 63] + "="; }
  return s;
}
function out(u, enc) { enc = (enc || "").toLowerCase(); if (enc === "hex") return toHex(u); if (enc === "base64") return toB64(u); return u; }

// ── SHA-256 ──
var K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2];
function rr(x, n) { return (x >>> n) | (x << (32 - n)); }
function sha256(msg) {
  var H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  var l = msg.length, withone = l + 1, padded = withone + ((56 - (withone % 64) + 64) % 64) + 8;
  var m = new Uint8Array(padded); m.set(msg); m[l] = 0x80;
  var bits = l * 8; for (var i = 0; i < 4; i++) m[padded - 1 - i] = (bits >>> (8 * i)) & 0xff;
  var w = new Int32Array(64);
  for (var off = 0; off < padded; off += 64) {
    for (var t = 0; t < 16; t++) w[t] = (m[off + t * 4] << 24) | (m[off + t * 4 + 1] << 16) | (m[off + t * 4 + 2] << 8) | (m[off + t * 4 + 3]);
    for (t = 16; t < 64; t++) {
      var s0 = rr(w[t - 15], 7) ^ rr(w[t - 15], 18) ^ (w[t - 15] >>> 3);
      var s1 = rr(w[t - 2], 17) ^ rr(w[t - 2], 19) ^ (w[t - 2] >>> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) | 0;
    }
    var a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
    for (t = 0; t < 64; t++) {
      var S1 = rr(e, 6) ^ rr(e, 11) ^ rr(e, 25), ch = (e & f) ^ (~e & g);
      var t1 = (h + S1 + ch + K[t] + w[t]) | 0;
      var S0 = rr(a, 2) ^ rr(a, 13) ^ rr(a, 22), maj = (a & b) ^ (a & c) ^ (b & c);
      var t2 = (S0 + maj) | 0;
      h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
    }
    H[0] = (H[0] + a) | 0; H[1] = (H[1] + b) | 0; H[2] = (H[2] + c) | 0; H[3] = (H[3] + d) | 0;
    H[4] = (H[4] + e) | 0; H[5] = (H[5] + f) | 0; H[6] = (H[6] + g) | 0; H[7] = (H[7] + h) | 0;
  }
  var dgst = new Uint8Array(32);
  for (i = 0; i < 8; i++) { dgst[i * 4] = (H[i] >>> 24) & 255; dgst[i * 4 + 1] = (H[i] >>> 16) & 255; dgst[i * 4 + 2] = (H[i] >>> 8) & 255; dgst[i * 4 + 3] = H[i] & 255; }
  return dgst;
}

// ── SHA-1 ──
function sha1(msg) {
  var l = msg.length, withone = l + 1, padded = withone + ((56 - (withone % 64) + 64) % 64) + 8;
  var m = new Uint8Array(padded); m.set(msg); m[l] = 0x80;
  var bits = l * 8; for (var i = 0; i < 4; i++) m[padded - 1 - i] = (bits >>> (8 * i)) & 0xff;
  var h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
  var w = new Int32Array(80);
  for (var off = 0; off < padded; off += 64) {
    for (var t = 0; t < 16; t++) w[t] = (m[off + t * 4] << 24) | (m[off + t * 4 + 1] << 16) | (m[off + t * 4 + 2] << 8) | m[off + t * 4 + 3];
    for (t = 16; t < 80; t++) { var x = w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16]; w[t] = (x << 1) | (x >>> 31); }
    var a = h0, b = h1, c = h2, d = h3, e = h4;
    for (t = 0; t < 80; t++) {
      var f, k;
      if (t < 20) { f = (b & c) | (~b & d); k = 0x5A827999; }
      else if (t < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1; }
      else if (t < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
      else { f = b ^ c ^ d; k = 0xCA62C1D6; }
      var tmp = (((a << 5) | (a >>> 27)) + f + e + k + w[t]) | 0;
      e = d; d = c; c = (b << 30) | (b >>> 2); b = a; a = tmp;
    }
    h0 = (h0 + a) | 0; h1 = (h1 + b) | 0; h2 = (h2 + c) | 0; h3 = (h3 + d) | 0; h4 = (h4 + e) | 0;
  }
  var dg = new Uint8Array(20), hs = [h0, h1, h2, h3, h4];
  for (i = 0; i < 5; i++) { dg[i * 4] = (hs[i] >>> 24) & 255; dg[i * 4 + 1] = (hs[i] >>> 16) & 255; dg[i * 4 + 2] = (hs[i] >>> 8) & 255; dg[i * 4 + 3] = hs[i] & 255; }
  return dg;
}

var ALGOS = { sha256: { fn: sha256, block: 64 }, sha1: { fn: sha1, block: 64 } };

function Hash(algo) { var a = ALGOS[String(algo).toLowerCase()]; if (!a) throw new Error("unsupported hash: " + algo); this._a = a; this._chunks = []; }
Hash.prototype.update = function (data, enc) { this._chunks.push(bytesOf(data, enc)); return this; };
Hash.prototype.digest = function (enc) {
  var total = this._chunks.reduce(function (n, c) { return n + c.length; }, 0);
  var all = new Uint8Array(total), o = 0;
  this._chunks.forEach(function (c) { all.set(c, o); o += c.length; });
  return out(this._a.fn(all), enc);
};

function Hmac(algo, key) {
  var a = ALGOS[String(algo).toLowerCase()]; if (!a) throw new Error("unsupported hash: " + algo);
  this._a = a; var k = bytesOf(key);
  if (k.length > a.block) k = a.fn(k);
  var bk = new Uint8Array(a.block); bk.set(k);
  this._ipad = new Uint8Array(a.block); this._opad = new Uint8Array(a.block);
  for (var i = 0; i < a.block; i++) { this._ipad[i] = bk[i] ^ 0x36; this._opad[i] = bk[i] ^ 0x5c; }
  this._chunks = [];
}
Hmac.prototype.update = Hash.prototype.update;
Hmac.prototype.digest = function (enc) {
  var total = this._chunks.reduce(function (n, c) { return n + c.length; }, 0);
  var inner = new Uint8Array(this._ipad.length + total); inner.set(this._ipad);
  var o = this._ipad.length; this._chunks.forEach(function (c) { inner.set(c, o); o += c.length; });
  var ih = this._a.fn(inner);
  var outer = new Uint8Array(this._opad.length + ih.length); outer.set(this._opad); outer.set(ih, this._opad.length);
  return out(this._a.fn(outer), enc);
}

function randomBytes(n) {
  var u = new Uint8Array(n);
  for (var i = 0; i < n; i++) u[i] = (Math.random() * 256) | 0;
  u.toString = function (enc) { return out(this, enc || "hex"); };
  return u;
}
function randomUUID() {
  var b = randomBytes(16); b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  var h = toHex(b);
  return h.slice(0, 8) + "-" + h.slice(8, 12) + "-" + h.slice(12, 16) + "-" + h.slice(16, 20) + "-" + h.slice(20);
}

module.exports = {
  createHash: function (a) { return new Hash(a); },
  createHmac: function (a, k) { return new Hmac(a, k); },
  randomBytes: randomBytes,
  randomUUID: randomUUID
};
