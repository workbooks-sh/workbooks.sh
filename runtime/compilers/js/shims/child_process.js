/* Node 'child_process' shim (JsDock lane) — backed by Javy.Exec.run (host_exec) → ExecBroker.
 * There is NO OS subprocess: exec dispatches to a REGISTERED in-sandbox wasm command (default-deny,
 * registered-only, no shell, output-capped). A "shell command string" is NOT parsed/interpreted —
 * the FIRST whitespace token is treated as the command name and the rest as literal argv (no shell
 * metacharacters, no injection). execSync/exec/spawnSync map onto the one brokered primitive. */
"use strict";
var EventEmitter = require("./events");

function run(name, argv, stdin) {
  if (typeof Javy === "undefined" || !Javy.Exec) {
    throw new Error("child_process: exec capability unavailable — JsDock lane + commands cap required");
  }
  return Javy.Exec.run(String(name), argv || [], stdin == null ? "" : String(stdin));
}

// Split a "command string" structurally — NO shell. First token = command, rest = literal args.
function splitCmd(cmd) {
  var parts = String(cmd).trim().split(/\s+/);
  return { name: parts[0], argv: parts.slice(1) };
}

// execSync(command[, opts]) -> stdout (string|Buffer). Throws on broker denial (out === null).
function execSync(command, opts) {
  opts = opts || {};
  var c = splitCmd(command);
  var out = run(c.name, c.argv, opts.input);
  if (out === null) { var e = new Error("Command failed: " + command); e.status = 1; throw e; }
  return out;
}

// execFileSync(file, args[, opts]) -> stdout. file is the command name (no shell parse).
function execFileSync(file, args, opts) {
  if (!Array.isArray(args)) { opts = args; args = []; }
  opts = opts || {};
  var out = run(file, args, opts.input);
  if (out === null) { var e = new Error("Command failed: " + file); e.status = 1; throw e; }
  return out;
}

// spawnSync(file, args[, opts]) -> {status, stdout, stderr}.
function spawnSync(file, args, opts) {
  if (!Array.isArray(args)) { opts = args; args = []; }
  opts = opts || {};
  var out;
  try { out = run(file, args, opts.input); } catch (e) { return { status: 1, stdout: "", stderr: String(e), error: e }; }
  if (out === null) return { status: 1, stdout: "", stderr: "command denied/failed", error: new Error("denied") };
  return { status: 0, stdout: out, stderr: "" };
}

// exec(command[, opts], cb): async-ish over a microtask. cb(err, stdout, stderr).
function exec(command, opts, cb) {
  if (typeof opts === "function") { cb = opts; opts = {}; }
  opts = opts || {};
  var c = splitCmd(command);
  var child = new EventEmitter();
  Promise.resolve().then(function () {
    var out;
    try { out = run(c.name, c.argv, opts.input); } catch (e) { if (cb) cb(e, "", String(e)); child.emit("error", e); return; }
    if (out === null) { var err = new Error("Command failed: " + command); err.code = 1; if (cb) cb(err, "", ""); child.emit("close", 1); return; }
    if (cb) cb(null, out, "");
    child.emit("close", 0);
  });
  return child;
}

// execFile(file, args[, opts], cb).
function execFile(file, args, opts, cb) {
  if (typeof args === "function") { cb = args; args = []; opts = {}; }
  else if (typeof opts === "function") { cb = opts; opts = {}; }
  return exec(file + (args && args.length ? " " + args.join(" ") : ""), opts, cb);
}

// spawn(file, args[, opts]) -> child with stdout EventEmitter + 'close'.
function spawn(file, args, opts) {
  if (!Array.isArray(args)) { opts = args; args = []; }
  opts = opts || {};
  var child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  Promise.resolve().then(function () {
    var out;
    try { out = run(file, args, opts.input); } catch (e) { child.emit("error", e); return; }
    if (out === null) { child.emit("close", 1); return; }
    child.stdout.emit("data", out);
    child.stdout.emit("end");
    child.emit("close", 0);
  });
  return child;
}

module.exports = {
  exec: exec, execSync: execSync, execFile: execFile, execFileSync: execFileSync,
  spawn: spawn, spawnSync: spawnSync
};
