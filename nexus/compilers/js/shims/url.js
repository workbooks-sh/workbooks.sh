/* Node 'url' shim (wb-spy.T2.1) — legacy parse/format + URLSearchParams + a minimal URL,
 * pure JS (QuickJS-ng has no global URL). */
"use strict";
var qs = require("./querystring");

function URLSearchParams(init) {
  this._m = [];
  if (typeof init === "string") {
    init = init.replace(/^\?/, "");
    var o = qs.parse(init);
    var self = this;
    Object.keys(o).forEach(function (k) {
      var v = o[k];
      if (Array.isArray(v)) v.forEach(function (x) { self._m.push([k, x]); });
      else self._m.push([k, v]);
    });
  } else if (init && typeof init === "object") {
    var s2 = this;
    Object.keys(init).forEach(function (k) { s2._m.push([k, String(init[k])]); });
  }
}
URLSearchParams.prototype.get = function (k) { for (var i = 0; i < this._m.length; i++) if (this._m[i][0] === k) return this._m[i][1]; return null; };
URLSearchParams.prototype.getAll = function (k) { return this._m.filter(function (p) { return p[0] === k; }).map(function (p) { return p[1]; }); };
URLSearchParams.prototype.has = function (k) { return this.get(k) !== null; };
URLSearchParams.prototype.set = function (k, v) { this.delete(k); this._m.push([k, String(v)]); };
URLSearchParams.prototype.append = function (k, v) { this._m.push([k, String(v)]); };
URLSearchParams.prototype.delete = function (k) { this._m = this._m.filter(function (p) { return p[0] !== k; }); };
URLSearchParams.prototype.toString = function () {
  return this._m.map(function (p) { return encodeURIComponent(p[0]) + "=" + encodeURIComponent(p[1]); }).join("&");
};

var RE = /^(?:([^:/?#]+):)?(?:\/\/([^/?#]*))?([^?#]*)(?:\?([^#]*))?(?:#(.*))?$/;
function parse(u, parseQuery) {
  var m = RE.exec(String(u)) || [];
  var protocol = m[1] ? m[1] + ":" : null;
  var host = m[2] || null;
  var hostParts = host ? host.split(":") : [];
  var search = m[4] != null ? "?" + m[4] : null;
  return {
    href: String(u), protocol: protocol, host: host,
    hostname: hostParts[0] || null, port: hostParts[1] || null,
    pathname: m[3] || null, search: search, hash: m[5] != null ? "#" + m[5] : null,
    query: parseQuery ? qs.parse(m[4] || "") : (m[4] || null)
  };
}
function format(o) {
  var s = "";
  if (o.protocol) s += o.protocol.replace(/:?$/, ":");
  if (o.host) s += "//" + o.host;
  else if (o.hostname) s += "//" + o.hostname + (o.port ? ":" + o.port : "");
  s += o.pathname || "";
  if (o.search) s += o.search;
  else if (o.query) s += "?" + (typeof o.query === "string" ? o.query : qs.stringify(o.query));
  if (o.hash) s += o.hash;
  return s;
}
function URL(input) {
  var p = parse(input, false);
  this.href = p.href; this.protocol = p.protocol || ""; this.hostname = p.hostname || "";
  this.port = p.port || ""; this.host = p.host || ""; this.pathname = p.pathname || "";
  this.search = p.search || ""; this.hash = p.hash || "";
  this.searchParams = new URLSearchParams(p.search || "");
}
URL.prototype.toString = function () { return this.href; };
module.exports = { parse: parse, format: format, URL: URL, URLSearchParams: URLSearchParams };
