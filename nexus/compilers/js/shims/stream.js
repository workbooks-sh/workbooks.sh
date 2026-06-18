/* Node 'stream' shim — pure-JS, minimal. Readable/Writable/Transform/PassThrough/Duplex built on the
 * events shim, buffering in memory (no real async I/O). Covers the common "pipe a small buffer through
 * a transform" usage some packages need; true backpressure/streaming is the documented frontier. */
"use strict";
var EventEmitter = require("./events");

function Readable(opts) { EventEmitter.call(this); this._buf = []; this.readable = true; }
Readable.prototype = Object.create(EventEmitter.prototype);
Readable.prototype.push = function (chunk) {
  if (chunk === null) { this.emit("end"); return false; }
  this._buf.push(chunk); this.emit("data", chunk); return true;
};
Readable.prototype.read = function () { return this._buf.length ? this._buf.shift() : null; };
Readable.prototype.pipe = function (dest) {
  this.on("data", function (c) { dest.write(c); });
  this.on("end", function () { if (dest.end) dest.end(); });
  return dest;
};
Readable.prototype.setEncoding = function () { return this; };
Readable.prototype.resume = function () { return this; };
Readable.prototype.pause = function () { return this; };

function Writable(opts) {
  EventEmitter.call(this);
  this.writable = true;
  this._chunks = [];
  this._writeFn = opts && opts.write;
}
Writable.prototype = Object.create(EventEmitter.prototype);
Writable.prototype.write = function (chunk, enc, cb) {
  if (typeof enc === "function") { cb = enc; enc = null; }
  this._chunks.push(chunk);
  if (this._writeFn) this._writeFn(chunk, enc, cb || function () {});
  else if (cb) cb();
  this.emit("data", chunk);
  return true;
};
Writable.prototype.end = function (chunk, enc, cb) {
  if (typeof chunk === "function") { cb = chunk; chunk = null; }
  else if (typeof enc === "function") { cb = enc; }
  if (chunk != null) this.write(chunk);
  this.emit("finish");
  this.emit("end");
  if (cb) cb();
  return this;
};

function Duplex(opts) { Readable.call(this, opts); Writable.call(this, opts); }
Duplex.prototype = Object.create(Readable.prototype);
Duplex.prototype.write = Writable.prototype.write;
Duplex.prototype.end = Writable.prototype.end;

function Transform(opts) {
  Duplex.call(this, opts);
  this._transform = (opts && opts.transform) || function (chunk, enc, cb) { cb(null, chunk); };
}
Transform.prototype = Object.create(Duplex.prototype);
Transform.prototype.write = function (chunk, enc, cb) {
  var self = this;
  if (typeof enc === "function") { cb = enc; enc = null; }
  this._transform(chunk, enc, function (err, out) {
    if (!err && out != null) self.push(out);
    if (cb) cb(err);
  });
  return true;
};

function PassThrough(opts) { Transform.call(this, opts); }
PassThrough.prototype = Object.create(Transform.prototype);

module.exports = {
  Readable: Readable, Writable: Writable, Duplex: Duplex,
  Transform: Transform, PassThrough: PassThrough, Stream: Readable
};
