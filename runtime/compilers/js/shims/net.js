/* Node 'net' shim (JsDock lane) — backed by Javy.Net.tcp (host_tcp) → TcpBroker (resolve-then-pin,
 * SSRF-safe). NOT a full streaming socket: it's a brokered request→response — whatever you write()
 * before end()/the implicit flush is sent as ONE payload, and the full response is delivered back as
 * a single 'data' then 'end'. Good enough for simple line/request protocols; persistent bidirectional
 * streaming is the documented frontier. Internal/SSRF targets are denied by the host broker. */
"use strict";
var EventEmitter = require("./events");

function rawTcp(host, port, data) {
  if (typeof Javy === "undefined" || !Javy.Net || !Javy.Net.tcp) {
    throw new Error("net: tcp capability unavailable — JsDock lane + tcp cap required");
  }
  return Javy.Net.tcp(String(host), port | 0, data == null ? "" : String(data));
}

function Socket() {
  EventEmitter.call(this);
  this._chunks = [];
  this._host = null;
  this._port = 0;
}
Socket.prototype = Object.create(EventEmitter.prototype);
Socket.prototype.connect = function (port, host, cb) {
  if (typeof port === "object") { host = port.host; port = port.port; }
  this._host = host || "localhost";
  this._port = port;
  if (typeof host === "function") cb = host;
  if (cb) this.on("connect", cb);
  var self = this;
  Promise.resolve().then(function () { self.emit("connect"); });
  return this;
};
Socket.prototype.write = function (d) { if (d != null) this._chunks.push(String(d)); return true; };
Socket.prototype.setEncoding = function () {};
Socket.prototype.setTimeout = function () {};
Socket.prototype.end = function (d) {
  if (d != null) this._chunks.push(String(d));
  var self = this;
  var payload = this._chunks.join("");
  Promise.resolve().then(function () {
    var resp;
    try { resp = rawTcp(self._host, self._port, payload); } catch (e) { self.emit("error", e); return; }
    if (resp === null) { self.emit("error", new Error("tcp connect/denied: " + self._host + ":" + self._port)); return; }
    self.emit("data", resp);
    self.emit("end");
    self.emit("close");
  });
  return this;
};
Socket.prototype.destroy = function () {};

function connect(port, host, cb) {
  var s = new Socket();
  s.connect(port, host, cb);
  return s;
}

module.exports = { Socket: Socket, connect: connect, createConnection: connect };
