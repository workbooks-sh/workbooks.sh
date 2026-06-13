/* Node 'dgram' shim (JsDock lane) — backed by Javy.Net.udp (host_udp) → UdpBroker (resolve-then-pin,
 * SSRF-safe, send-one/recv-one). NOT a persistent socket: each send() is a brokered datagram and the
 * single reply (if any) is delivered as a 'message' event. Good enough for simple request/reply UDP
 * (DNS-ish, STUN-ish); persistent multi-packet flows are the documented frontier. */
"use strict";
var EventEmitter = require("./events");

function rawUdp(host, port, data) {
  if (typeof Javy === "undefined" || !Javy.Net || !Javy.Net.udp) {
    throw new Error("dgram: udp capability unavailable — JsDock lane + udp cap required");
  }
  return Javy.Net.udp(String(host), port | 0, data == null ? "" : String(data));
}

function Socket() { EventEmitter.call(this); }
Socket.prototype = Object.create(EventEmitter.prototype);
Socket.prototype.bind = function (port, cb) { if (typeof cb === "function") cb(); var self = this; Promise.resolve().then(function () { self.emit("listening"); }); return this; };
// send(msg, [offset, length,] port, host[, cb])
Socket.prototype.send = function (msg) {
  var args = Array.prototype.slice.call(arguments, 1);
  // drop optional offset/length numbers preceding port
  while (args.length > 2 && typeof args[0] === "number" && typeof args[1] === "number" && typeof args[2] === "number") args.shift();
  var port = args[0], host = args[1], cb = typeof args[2] === "function" ? args[2] : null;
  var self = this;
  Promise.resolve().then(function () {
    var resp;
    try { resp = rawUdp(host, port, msg); } catch (e) { if (cb) cb(e); self.emit("error", e); return; }
    if (resp === null) { var err = new Error("udp send/denied: " + host + ":" + port); if (cb) cb(err); self.emit("error", err); return; }
    if (cb) cb(null);
    self.emit("message", resp, { address: host, port: port });
  });
  return this;
};
Socket.prototype.close = function (cb) { if (typeof cb === "function") cb(); this.emit("close"); };

function createSocket() { return new Socket(); }

module.exports = { createSocket: createSocket, Socket: Socket };
