/* Node 'process' shim (wb-spy.T2.1) — pure JS, no caps. stdout/stderr write via Javy.IO
 * (the harness's only IO surface); env/argv are empty; exit is a no-op. */
"use strict";
function w(fd, s) {
  try { Javy.IO.writeSync(fd, new TextEncoder().encode(String(s))); return true; } catch (e) { return false; }
}
var process = {
  env: {},
  argv: ["node", "script"],
  argv0: "node",
  platform: "wasm",
  arch: "wasm32",
  version: "v18.0.0",
  versions: { node: "18.0.0" },
  pid: 1,
  cwd: function () { return "/"; },
  chdir: function () {},
  nextTick: function (fn) { var a = Array.prototype.slice.call(arguments, 1); Promise.resolve().then(function () { fn.apply(null, a); }); },
  hrtime: function (prev) { var t = [0, 0]; if (prev) { return [0, 0]; } return t; },
  exit: function () {},
  on: function () { return process; },
  once: function () { return process; },
  off: function () { return process; },
  emit: function () { return false; },
  emitWarning: function () {},
  stdout: { write: function (s) { return w(1, s); }, isTTY: false },
  stderr: { write: function (s) { return w(2, s); }, isTTY: false }
};
process.hrtime.bigint = function () { return 0n; };
module.exports = process;
