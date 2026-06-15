// Standalone JS evaluation, sandboxed — NEVER eval in the host page.
//
// We run the snippet inside a Web Worker created from a Blob URL. The worker has
// no DOM, no parent window, no access to the page's globals; `console.*` and the
// return value are streamed back as messages and rendered in the output pane. A
// wall-clock timeout terminates runaway code. This is the zero-runtime floor for
// the `js` language; compiled languages (C/Rust/Zig/Go) route through the Host
// compiler lane instead (see wb-repl.js).
//
// (A worker is still same-origin; for fully-untrusted third-party code the next
// rung is a sandboxed cross-origin <iframe>. The public API here — runJs() →
// {ok, output, value} — is identical either way, so the surface can harden
// without changing callers.)

const WORKER_SRC = `
  self.onmessage = (e) => {
    const code = e.data.code;
    const logs = [];
    const fmt = (a) => {
      try {
        if (typeof a === "string") return a;
        if (a instanceof Error) return a.name + ": " + a.message;
        return JSON.stringify(a, (k, v) => typeof v === "bigint" ? v.toString() + "n" : v, 2);
      } catch (_) { return String(a); }
    };
    const line = (level, args) => logs.push({ level, text: args.map(fmt).join(" ") });
    const console = {
      log: (...a) => line("log", a),
      info: (...a) => line("info", a),
      warn: (...a) => line("warn", a),
      error: (...a) => line("error", a),
      debug: (...a) => line("debug", a),
    };
    let ok = true, value;
    try {
      // strict-mode function scope; no access to self/postMessage from user code
      const fn = new Function("console", '"use strict";\\n' + code);
      value = fn(console);
    } catch (err) {
      ok = false;
      logs.push({ level: "error", text: (err && err.name ? err.name + ": " + err.message : String(err)) });
    }
    const done = (v) => self.postMessage({ ok, logs, value: v === undefined ? undefined : fmt(v) });
    // resolve a returned promise so async snippets show their result
    if (value && typeof value.then === "function") {
      value.then((v) => done(v), (err) => { logs.push({ level: "error", text: String(err && err.message || err) }); self.postMessage({ ok: false, logs, value: undefined }); });
    } else {
      done(value);
    }
  };
`;

/**
 * Run a JS snippet in a fresh sandboxed worker.
 * @returns {Promise<{ok:boolean, output:string, value?:string}>}
 */
export function runJs(code, { timeoutMs = 4000 } = {}) {
  return new Promise((resolve) => {
    let url, worker, timer;
    const cleanup = () => {
      clearTimeout(timer);
      if (worker) worker.terminate();
      if (url) URL.revokeObjectURL(url);
    };
    const finish = (res) => { cleanup(); resolve(res); };

    try {
      url = URL.createObjectURL(new Blob([WORKER_SRC], { type: "text/javascript" }));
      worker = new Worker(url);
    } catch (e) {
      return finish({ ok: false, output: "sandbox unavailable: " + (e.message || e) });
    }

    timer = setTimeout(() => {
      finish({ ok: false, output: "execution timed out (" + timeoutMs + "ms) — terminated runaway code." });
    }, timeoutMs);

    worker.onmessage = (e) => {
      const { ok, logs, value } = e.data || {};
      const parts = (logs || []).map((l) => l.text);
      if (value !== undefined) parts.push("⇒ " + value);
      finish({ ok: !!ok, output: parts.join("\n"), value });
    };
    worker.onerror = (e) => finish({ ok: false, output: "worker error: " + (e.message || "unknown") });

    worker.postMessage({ code });
  });
}
