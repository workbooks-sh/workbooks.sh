/* Node 'http' shim + WHATWG fetch (wb-e1x.4 / JD.4) — backed by Javy.Net.get (host_http_get) via
 * JsDock, host-brokered egress (Route B: the wasm never opens a socket). Only works in the :dock
 * lane on a net-capable Policy profile; otherwise Javy.Net.get returns null → calls fail/emit error.
 * GET-only and synchronous-under-the-hood (the host fetch is blocking); responses are delivered on
 * a microtask so the EventEmitter/Promise contracts hold. Good enough for simple clients; streaming
 * uploads / non-GET / keep-alive are the documented frontier. */
"use strict";
var EventEmitter = require("./events");

function getBody(url) {
  if (typeof Javy === "undefined" || !Javy.Net) {
    throw new Error("http: network capability unavailable — JsDock lane + net profile required");
  }
  return Javy.Net.get(String(url)); // body string, or null (denied / error)
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

// http.get(url[, opts], cb): cb(res); res emits 'data' (body) then 'end' on a microtask.
function get(a, b, c) {
  var url = urlOf(a);
  var cb = typeof b === "function" ? b : c;
  var res = new EventEmitter();
  res.statusCode = 200;
  res.headers = {};
  res.setEncoding = function () {};
  if (cb) cb(res);
  Promise.resolve().then(function () {
    var body = getBody(url);
    if (body === null) { res.emit("error", new Error("request failed: " + url)); return; }
    res.emit("data", body);
    res.emit("end");
  });
  var req = new EventEmitter();
  req.end = function () { return req; };
  req.abort = function () {};
  return req;
}

function request(a, b, c) { return get(a, b, c); }

// WHATWG fetch(url) -> Promise<Response-like>. Body resolved via the host on a microtask.
function fetch(url) {
  return Promise.resolve().then(function () {
    var body = getBody(typeof url === "object" && url.url ? url.url : url);
    if (body === null) throw new Error("fetch failed: " + url);
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
  METHODS: ["GET"],
  STATUS_CODES: { 200: "OK" },
  globalAgent: {}
};
