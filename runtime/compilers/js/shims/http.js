/* Node 'http' shim + WHATWG fetch (wb-e1x.4 / JD.4) — backed by Javy.Net via JsDock, host-brokered
 * egress (Route B: the wasm never opens a socket). Only works in the :dock lane on a net-capable
 * Policy profile; otherwise Javy.Net.* returns null → calls fail/emit error. GET via Javy.Net.get;
 * POST/PUT/other methods + a request body via Javy.Net.request (host_http). The host fetch is
 * blocking; responses are delivered on a microtask so the EventEmitter/Promise contracts hold.
 * Streaming uploads / keep-alive remain the documented frontier. */
"use strict";
var EventEmitter = require("./events");

function ensureNet() {
  if (typeof Javy === "undefined" || !Javy.Net) {
    throw new Error("http: network capability unavailable — JsDock lane + net profile required");
  }
}

// Brokered request. method GET → Javy.Net.get (back-compat); anything else (or a body) → host_http.
function doRequest(url, method, headers, body) {
  ensureNet();
  url = String(url);
  method = (method || "GET").toUpperCase();
  if (method === "GET" && body == null) return Javy.Net.get(url); // body string | null
  return Javy.Net.request(method, url, body == null ? "" : String(body), headers || {});
}

// Build a request URL from a string or a Node options object ({protocol,hostname,port,path}).
function urlOf(opts) {
  if (typeof opts === "string") return opts;
  var proto = (opts.protocol || "http:").replace(/:?$/, ":");
  var host = opts.hostname || opts.host || "localhost";
  var port = opts.port ? ":" + opts.port : "";
  var path = opts.path || "/";
  return proto + "//" + host + port + path;
}

function methodOf(opts) { return typeof opts === "object" && opts.method ? opts.method : "GET"; }
function headersOf(opts) { return typeof opts === "object" && opts.headers ? opts.headers : {}; }

// http.request(url[, opts], cb): returns a writable-ish req; write()/end(body) sends, cb(res) fires.
function request(a, b, c) {
  var url = urlOf(a);
  var method = methodOf(typeof a === "object" ? a : b);
  var headers = headersOf(typeof a === "object" ? a : b);
  var cb = typeof b === "function" ? b : c;

  var req = new EventEmitter();
  var chunks = [];
  req.write = function (d) { if (d != null) chunks.push(String(d)); return true; };
  req.setHeader = function (k, v) { headers[k] = v; };
  req.abort = function () {};
  req.end = function (d) {
    if (d != null) chunks.push(String(d));
    var body = chunks.join("");
    Promise.resolve().then(function () {
      var res = new EventEmitter();
      res.statusCode = 200;
      res.headers = {};
      res.setEncoding = function () {};
      if (cb) cb(res);
      var out;
      try { out = doRequest(url, method, headers, method === "GET" ? null : body); }
      catch (e) { res.emit("error", e); return; }
      if (out === null) { res.emit("error", new Error("request failed: " + url)); return; }
      res.emit("data", out);
      res.emit("end");
    });
    return req;
  };
  return req;
}

// http.get(url[, opts], cb): convenience GET that auto-ends.
function get(a, b, c) {
  var req = request(a, b, c);
  req.end();
  return req;
}

// WHATWG fetch(url[, init]) -> Promise<Response-like>. init: {method, headers, body}.
function fetch(url, init) {
  init = init || {};
  return Promise.resolve().then(function () {
    var u = typeof url === "object" && url.url ? url.url : url;
    var body = doRequest(u, init.method, init.headers, init.body);
    if (body === null) throw new Error("fetch failed: " + u);
    return {
      ok: true,
      status: 200,
      statusText: "OK",
      headers: { get: function () { return null; } },
      text: function () { return Promise.resolve(body); },
      json: function () { return Promise.resolve(JSON.parse(body)); },
      arrayBuffer: function () { return Promise.resolve(new TextEncoder().encode(body).buffer); }
    };
  });
}

module.exports = {
  get: get,
  request: request,
  fetch: fetch,
  METHODS: ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"],
  STATUS_CODES: { 200: "OK" },
  globalAgent: {}
};
