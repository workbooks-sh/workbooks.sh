/* Node 'util' shim (wb-spy.T2.1) — inherits/format/inspect/promisify/types, pure JS. */
"use strict";
function inherits(ctor, sup) {
  ctor.super_ = sup;
  ctor.prototype = Object.create(sup.prototype, { constructor: { value: ctor, enumerable: false, writable: true, configurable: true } });
}
function inspect(o) {
  try { return typeof o === "string" ? o : JSON.stringify(o); } catch (e) { return String(o); }
}
function format(f) {
  var args = Array.prototype.slice.call(arguments, 1), i = 0;
  if (typeof f !== "string") { return [f].concat(args).map(inspect).join(" "); }
  var out = f.replace(/%[sdjifoO%]/g, function (m) {
    if (m === "%%") return "%";
    if (i >= args.length) return m;
    var a = args[i++];
    if (m === "%d" || m === "%i") return String(parseInt(a, 10));
    if (m === "%f") return String(parseFloat(a));
    if (m === "%j") { try { return JSON.stringify(a); } catch (e) { return "[Circular]"; } }
    if (m === "%s") return String(a);
    return inspect(a);
  });
  for (; i < args.length; i++) out += " " + (typeof args[i] === "string" ? args[i] : inspect(args[i]));
  return out;
}
function promisify(fn) {
  return function () {
    var args = Array.prototype.slice.call(arguments), self = this;
    return new Promise(function (resolve, reject) {
      args.push(function (err, val) { if (err) reject(err); else resolve(val); });
      fn.apply(self, args);
    });
  };
}
function deprecate(fn) { return fn; }
var types = {
  isArrayBuffer: function (x) { return x instanceof ArrayBuffer; },
  isTypedArray: function (x) { return ArrayBuffer.isView(x) && !(x instanceof DataView); },
  isUint8Array: function (x) { return x instanceof Uint8Array; },
  isDate: function (x) { return x instanceof Date; },
  isRegExp: function (x) { return x instanceof RegExp; }
};
module.exports = {
  inherits: inherits, format: format, inspect: inspect, promisify: promisify,
  deprecate: deprecate, types: types,
  isArray: Array.isArray,
  isBuffer: function (x) { return !!(x && (x.__isBuffer || x instanceof Uint8Array)); },
  isFunction: function (x) { return typeof x === "function"; },
  isString: function (x) { return typeof x === "string"; },
  isObject: function (x) { return x !== null && typeof x === "object"; },
  isNullOrUndefined: function (x) { return x == null; }
};
