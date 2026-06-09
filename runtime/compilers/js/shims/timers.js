/* Node 'timers' shim (wb-spy.T2.4) — pure JS. The harness drains the microtask queue after eval
 * (JS_ExecutePendingJob loop), so callbacks are scheduled as microtasks. There is no real timer
 * thread: delay ordering is NOT honored and setInterval does NOT repeat (single fire) — same model
 * tsjob.js uses. Requiring this module also installs the functions as globals for code that calls
 * setTimeout/queueMicrotask without importing. */
"use strict";
function setTimeout_(fn) {
  var args = Array.prototype.slice.call(arguments, 2);
  Promise.resolve().then(function () { try { fn.apply(null, args); } catch (e) {} });
  return 0;
}
function setInterval_(fn) {
  var args = Array.prototype.slice.call(arguments, 2);
  Promise.resolve().then(function () { try { fn.apply(null, args); } catch (e) {} });
  return 0;
}
function setImmediate_(fn) {
  var args = Array.prototype.slice.call(arguments, 1);
  Promise.resolve().then(function () { try { fn.apply(null, args); } catch (e) {} });
  return 0;
}
function noop() {}
function queueMicrotask_(fn) { Promise.resolve().then(fn); }

var api = {
  setTimeout: setTimeout_, clearTimeout: noop,
  setInterval: setInterval_, clearInterval: noop,
  setImmediate: setImmediate_, clearImmediate: noop,
  queueMicrotask: queueMicrotask_
};

// Install as globals (idempotent) so bare setTimeout(...) works too.
Object.keys(api).forEach(function (k) {
  if (typeof globalThis[k] !== "function") globalThis[k] = api[k];
});

module.exports = api;
