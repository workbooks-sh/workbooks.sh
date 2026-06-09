/* Node 'querystring' shim (wb-spy.T2.1) — parse/stringify/escape/unescape, pure JS. */
"use strict";
function escape(s) { return encodeURIComponent(String(s)); }
function unescape(s) { try { return decodeURIComponent(String(s)); } catch (e) { return String(s); } }
function parse(str, sep, eq) {
  sep = sep || "&"; eq = eq || "=";
  var obj = {};
  if (!str) return obj;
  var pairs = String(str).split(sep);
  for (var i = 0; i < pairs.length; i++) {
    if (!pairs[i]) continue;
    var idx = pairs[i].indexOf(eq);
    var k = idx < 0 ? pairs[i] : pairs[i].slice(0, idx);
    var v = idx < 0 ? "" : pairs[i].slice(idx + 1);
    k = unescape(k); v = unescape(v);
    if (Object.prototype.hasOwnProperty.call(obj, k)) {
      if (Array.isArray(obj[k])) obj[k].push(v); else obj[k] = [obj[k], v];
    } else obj[k] = v;
  }
  return obj;
}
function stringify(obj, sep, eq) {
  sep = sep || "&"; eq = eq || "=";
  if (!obj) return "";
  var out = [];
  Object.keys(obj).forEach(function (k) {
    var v = obj[k], ek = escape(k);
    if (Array.isArray(v)) v.forEach(function (x) { out.push(ek + eq + escape(x)); });
    else out.push(ek + eq + escape(v));
  });
  return out.join(sep);
}
module.exports = { parse: parse, stringify: stringify, decode: parse, encode: stringify, escape: escape, unescape: unescape };
