/* Node 'assert' shim (wb-spy.T2.1) — core assertions, pure JS. */
"use strict";
function AssertionError(msg) { var e = new Error(msg || "assertion failed"); e.name = "AssertionError"; e.code = "ERR_ASSERTION"; return e; }
function deepEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== "object" || typeof b !== "object" || a == null || b == null) return a == b;
  var ka = Object.keys(a), kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  for (var i = 0; i < ka.length; i++) if (!deepEqual(a[ka[i]], b[ka[i]])) return false;
  return true;
}
function deepStrictEqual(a, b) {
  if (a === b) return true;
  if (typeof a !== "object" || typeof b !== "object" || a == null || b == null) return false;
  var ka = Object.keys(a), kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  for (var i = 0; i < ka.length; i++) if (!deepStrictEqual(a[ka[i]], b[ka[i]])) return false;
  return true;
}
function assert(v, msg) { if (!v) throw AssertionError(msg || "false == true"); }
assert.ok = assert;
assert.equal = function (a, b, m) { if (a != b) throw AssertionError(m || a + " == " + b); };
assert.notEqual = function (a, b, m) { if (a == b) throw AssertionError(m || a + " != " + b); };
assert.strictEqual = function (a, b, m) { if (a !== b) throw AssertionError(m || a + " === " + b); };
assert.notStrictEqual = function (a, b, m) { if (a === b) throw AssertionError(m || a + " !== " + b); };
assert.deepEqual = function (a, b, m) { if (!deepEqual(a, b)) throw AssertionError(m || "deepEqual"); };
assert.deepStrictEqual = function (a, b, m) { if (!deepStrictEqual(a, b)) throw AssertionError(m || "deepStrictEqual"); };
assert.throws = function (fn, m) { var t = false; try { fn(); } catch (e) { t = true; } if (!t) throw AssertionError(m || "missing expected exception"); };
assert.AssertionError = AssertionError;
module.exports = assert;
