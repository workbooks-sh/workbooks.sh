/* Node 'child_process' shim — StarlingMonkey eval lane (SLICE 1, wb-b9xv.9).
 *
 * The SM lane has NO Javy.* and NO host import surface beyond wasi:http; its only seam to the host is a
 * guest fetch(). So `run()` dispatches over fetch() to the FIXED internal sentinel URL that the vendored
 * WasiHttpView pins to the in-process ExecLoopback listener -> Workbooks.ExecBroker (default-deny,
 * REGISTERED-only, no shell, output-capped). There is NO OS subprocess: a "command" is a REGISTERED
 * in-sandbox wasm CLI run by the host. A command-string is split STRUCTURALLY (first token = command,
 * rest = literal argv) — never shell-parsed, no metacharacters, no injection.
 *
 * SEMANTIC ADJUSTMENT vs the Javy/QuickJS lane (flagged in the map): on SM the dispatch primitive is an
 * ASYNC fetch — SpiderMonkey can't block synchronously on it — so the *Sync variants here resolve to a
 * Promise (await it). The async surface (exec/execFile/spawn) is the idiomatic path. The host seam +
 * security spine are otherwise identical; one-shot buffered semantics are preserved (a single
 * execFile('rg',...) yields buffered stdout). The boot seam supplies the URL + grant token. */
"use strict";
var EventEmitter = require("./events");

// __wbExec is injected by JsEngine.run_node when exec is granted: { url, token }. Absent => exec disabled.
function cfg() {
  var c = (typeof globalThis !== "undefined" && globalThis.__wbExec) || null;
  if (!c || !c.url) throw new Error("child_process: exec capability unavailable (no exec grant on this run)");
  return c;
}

// run(name, argv, stdin) -> Promise<string|null>. null = broker denial (non-200). Buffered one-shot.
function run(name, argv, stdin) {
  var c = cfg();
  var body = JSON.stringify({ name: String(name), argv: argv || [], stdin: stdin == null ? "" : String(stdin) });
  return fetch(c.url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-wb-exec": c.token },
    body: body
  }).then(function (res) {
    if (!res.ok) return null;          // 403 => default-deny / unregistered
    return res.text();
  });
}

// Split a command string structurally — NO shell. First token = command, rest = literal args.
function splitCmd(cmd) {
  var parts = String(cmd).trim().split(/\s+/);
  return { name: parts[0], argv: parts.slice(1) };
}

// ── async surface (idiomatic on SM) ──────────────────────────────────────────────────────────

// exec(command[, opts], cb) — cb(err, stdout, stderr). Returns an EventEmitter ('close'/'error').
function exec(command, opts, cb) {
  if (typeof opts === "function") { cb = opts; opts = {}; }
  opts = opts || {};
  var c = splitCmd(command);
  var child = new EventEmitter();
  run(c.name, c.argv, opts.input).then(function (out) {
    if (out === null) { var err = new Error("Command failed: " + command); err.code = 1; if (cb) cb(err, "", ""); child.emit("close", 1); return; }
    if (cb) cb(null, out, "");
    child.emit("close", 0);
  }).catch(function (e) { if (cb) cb(e, "", String(e)); child.emit("error", e); });
  return child;
}

// execFile(file, args[, opts], cb).
function execFile(file, args, opts, cb) {
  if (typeof args === "function") { cb = args; args = []; opts = {}; }
  else if (typeof opts === "function") { cb = opts; opts = {}; }
  if (!Array.isArray(args)) { args = []; }
  opts = opts || {};
  var child = new EventEmitter();
  run(file, args, opts.input).then(function (out) {
    if (out === null) { var err = new Error("Command failed: " + file); err.code = 1; if (cb) cb(err, "", ""); child.emit("close", 1); return; }
    if (cb) cb(null, out, "");
    child.emit("close", 0);
  }).catch(function (e) { if (cb) cb(e, "", String(e)); child.emit("error", e); });
  return child;
}

// spawn(file, args[, opts]) -> child with stdout/stderr EventEmitters + 'close'.
function spawn(file, args, opts) {
  if (!Array.isArray(args)) { opts = args; args = []; }
  opts = opts || {};
  var child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  run(file, args, opts.input).then(function (out) {
    if (out === null) { child.emit("close", 1); return; }
    child.stdout.emit("data", out);
    child.stdout.emit("end");
    child.emit("close", 0);
  }).catch(function (e) { child.emit("error", e); });
  return child;
}

// ── *Sync surface — returns a Promise on SM (await it). Throws on denial when awaited. ─────────

function execSync(command, opts) {
  opts = opts || {};
  var c = splitCmd(command);
  return run(c.name, c.argv, opts.input).then(function (out) {
    if (out === null) { var e = new Error("Command failed: " + command); e.status = 1; throw e; }
    return out;
  });
}

function execFileSync(file, args, opts) {
  if (!Array.isArray(args)) { opts = args; args = []; }
  opts = opts || {};
  return run(file, args, opts.input).then(function (out) {
    if (out === null) { var e = new Error("Command failed: " + file); e.status = 1; throw e; }
    return out;
  });
}

function spawnSync(file, args, opts) {
  if (!Array.isArray(args)) { opts = args; args = []; }
  opts = opts || {};
  return run(file, args, opts.input).then(function (out) {
    if (out === null) return { status: 1, stdout: "", stderr: "command denied/failed", error: new Error("denied") };
    return { status: 0, stdout: out, stderr: "" };
  }).catch(function (e) { return { status: 1, stdout: "", stderr: String(e), error: e }; });
}

module.exports = {
  exec: exec, execSync: execSync, execFile: execFile, execFileSync: execFileSync,
  spawn: spawn, spawnSync: spawnSync
};
