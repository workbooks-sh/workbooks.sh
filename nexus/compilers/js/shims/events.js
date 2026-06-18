/* Node 'events' shim (wb-spy.T2.1) — pure JS EventEmitter, no caps. */
"use strict";
function EventEmitter() { this._events = Object.create(null); }
EventEmitter.prototype.on = function (t, fn) {
  (this._events[t] || (this._events[t] = [])).push(fn);
  return this;
};
EventEmitter.prototype.addListener = EventEmitter.prototype.on;
EventEmitter.prototype.once = function (t, fn) {
  var self = this;
  function g() { self.removeListener(t, g); return fn.apply(this, arguments); }
  g.listener = fn;
  return this.on(t, g);
};
EventEmitter.prototype.removeListener = function (t, fn) {
  var a = this._events[t];
  if (a) {
    for (var i = a.length - 1; i >= 0; i--) {
      if (a[i] === fn || a[i].listener === fn) a.splice(i, 1);
    }
  }
  return this;
};
EventEmitter.prototype.off = EventEmitter.prototype.removeListener;
EventEmitter.prototype.removeAllListeners = function (t) {
  if (t === undefined) this._events = Object.create(null);
  else delete this._events[t];
  return this;
};
EventEmitter.prototype.emit = function (t) {
  var a = this._events[t];
  if (!a) return false;
  var args = Array.prototype.slice.call(arguments, 1);
  var copy = a.slice();
  for (var i = 0; i < copy.length; i++) copy[i].apply(this, args);
  return true;
};
EventEmitter.prototype.listeners = function (t) { return (this._events[t] || []).slice(); };
EventEmitter.prototype.listenerCount = function (t) { return (this._events[t] || []).length; };
EventEmitter.prototype.setMaxListeners = function () { return this; };
EventEmitter.EventEmitter = EventEmitter;
module.exports = EventEmitter;
