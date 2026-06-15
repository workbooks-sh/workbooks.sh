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

// Derive the streaming endpoints from the exec sentinel base (…/__wb/exec → …/__wb/{spawn,stream,stdin}).
function base() { return cfg().url.replace(/\/__wb\/exec$/, "/__wb"); }
function shdr() { return { "content-type": "application/json", "x-wb-exec": cfg().token }; }

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

// spawn(file, args[, opts]) -> a LONG-LIVED streaming child (wb-b9xv.11). Unlike exec/execFile (buffered
// one-shot), this drives the streaming protocol: POST /__wb/spawn → handle, then long-poll /__wb/stream/<h>
// emitting each incremental chunk as a stdout 'data' event (the harness sees output as the inner CLI flushes
// it, NOT all-at-end), and child.stdin.write() POSTs /__wb/stdin/<h>. On exit it emits stdout 'end' then
// 'exit'/'close' with the propagated code. A broker denial (no handle) emits 'error'. Honest granularity:
// chunk cadence == the inner wasm CLI's own stdout flush cadence (wasmtime doesn't buffer the guest's fd 1).
function spawn(file, args, opts) {
  if (!Array.isArray(args)) { opts = args; args = []; }
  opts = opts || {};
  var child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.killed = false;

  // a writable stdin: write(bytes)->POST /__wb/stdin/<handle>. Buffered until the handle exists.
  var handle = null, pendingStdin = [];
  child.stdin = {
    write: function (data) {
      if (handle) { fetch(base() + "/stdin/" + handle, { method: "POST", headers: shdr(), body: JSON.stringify({ data: String(data) }) }); }
      else { pendingStdin.push(String(data)); }
      return true;
    },
    end: function (data) { if (data != null) this.write(data); }
  };

  fetch(base() + "/spawn", { method: "POST", headers: shdr(), body: JSON.stringify({ name: String(file), argv: args || [] }) })
    .then(function (res) {
      if (!res.ok) { child.emit("error", new Error("spawn denied: " + file)); return; }
      return res.json();
    })
    .then(function (j) {
      if (!j || !j.handle) return;
      handle = j.handle;
      // flush any stdin queued before the handle landed.
      var q = pendingStdin; pendingStdin = [];
      q.forEach(function (d) { fetch(base() + "/stdin/" + handle, { method: "POST", headers: shdr(), body: JSON.stringify({ data: d }) }); });
      if (opts.input != null) child.stdin.write(opts.input);

      // long-poll loop: each /__wb/stream/<handle> returns the bytes produced since the last poll. A
      // non-empty body is emitted immediately as an incremental 'data' (the streaming proof). x-wb-done:1
      // ends the loop, emitting 'end' + 'exit'/'close' with the propagated exit code.
      function pump() {
        if (child.killed) return;
        fetch(base() + "/stream/" + handle, { method: "POST", headers: shdr() })
          .then(function (res) {
            if (!res.ok) { child.emit("error", new Error("stream denied")); return; }
            var done = res.headers.get("x-wb-done") === "1";
            var code = res.headers.get("x-wb-exit");
            return res.text().then(function (chunk) {
              if (chunk && chunk.length) child.stdout.emit("data", chunk);
              if (done) {
                child.stdout.emit("end");
                var ec = code == null ? 0 : parseInt(code, 10);
                child.emit("exit", ec, null);
                child.emit("close", ec);
              } else {
                pump();
              }
            });
          })
          .catch(function (e) { child.emit("error", e); });
      }
      pump();
    })
    .catch(function (e) { child.emit("error", e); });

  child.kill = function () { child.killed = true; child.emit("close", 137); };
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
