// Workbooks Browser SDK (wb-aakl.15) — the client a dock-mounted toolkit UI
// loads to drive the host browser. Framework-agnostic; no build step.
//
//   <script src="/browser-sdk.js"></script>
//   const wb = window.workbooks.browser;
//   await wb.tabs.open("notes/today.html");
//   wb.on("tab-changed", (t) => render(t));
//
// Talks to the host (the browser shell) over postMessage per the protocol
// in src/lib/sdk/protocol.ts. Also performs the wb-theme handshake so the
// toolkit's own :root inherits the host theme tokens automatically.
(function () {
  "use strict";
  if (window.workbooks && window.workbooks.browser) return;

  var SDK_CALL = "wb-sdk-call";
  var SDK_REPLY = "wb-sdk-reply";
  var SDK_EVENT = "wb-sdk-event";

  var pending = {}; // id → {resolve, reject}
  var listeners = {}; // event → [cb]
  var seq = 0;

  function call(method, args) {
    return new Promise(function (resolve, reject) {
      var id = "c" + ++seq;
      pending[id] = { resolve: resolve, reject: reject };
      parent.postMessage({ type: SDK_CALL, id: id, method: method, args: args || [] }, "*");
      setTimeout(function () {
        if (pending[id]) {
          delete pending[id];
          reject(new Error("SDK call timed out: " + method));
        }
      }, 10000);
    });
  }

  function on(event, cb) {
    (listeners[event] = listeners[event] || []).push(cb);
    return function off() {
      listeners[event] = (listeners[event] || []).filter(function (f) {
        return f !== cb;
      });
    };
  }

  function applyTokens(tokens) {
    if (!tokens) return;
    var root = document.documentElement;
    for (var k in tokens) {
      if (Object.prototype.hasOwnProperty.call(tokens, k)) {
        root.style.setProperty("--" + k, tokens[k]);
      }
    }
  }

  window.addEventListener("message", function (e) {
    var d = e.data;
    if (!d || typeof d !== "object") return;
    if (d.type === SDK_REPLY) {
      var p = pending[d.id];
      if (!p) return;
      delete pending[d.id];
      if (d.ok) p.resolve(d.result);
      else p.reject(new Error(d.error || "SDK error"));
    } else if (d.type === SDK_EVENT) {
      (listeners[d.event] || []).forEach(function (cb) {
        try {
          cb(d.payload);
        } catch (err) {
          console.error("[wb-sdk] listener error", err);
        }
      });
    } else if (d.type === "wb-theme") {
      applyTokens(d.tokens);
      (listeners["theme-changed"] || []).forEach(function (cb) {
        try {
          cb(d.tokens);
        } catch (_e) {}
      });
    }
  });

  // Signal readiness so the host posts the initial theme tokens.
  function signalReady() {
    parent.postMessage({ type: "wb-theme-ready" }, "*");
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", signalReady);
  } else {
    signalReady();
  }

  window.workbooks = window.workbooks || {};
  window.workbooks.browser = {
    tabs: {
      list: function () { return call("tabs.list"); },
      active: function () { return call("tabs.active"); },
      open: function (path) { return call("tabs.open", [path]); },
      focus: function (id) { return call("tabs.focus", [id]); },
      close: function (id) { return call("tabs.close", [id]); },
    },
    bookmarks: {
      list: function () { return call("bookmarks.list"); },
      add: function (title, path) { return call("bookmarks.add", [title, path]); },
      remove: function (id) { return call("bookmarks.remove", [id]); },
    },
    workspace: {
      active: function () { return call("workspace.active"); },
      list: function () { return call("workspace.list"); },
    },
    package: {
      active: function () { return call("package.active"); },
    },
    viewer: {
      current: function () { return call("viewer.current"); },
    },
    nexus: {
      active: function () { return call("nexus.active"); },
    },
    theme: {
      tokens: function () { return call("theme.tokens"); },
    },
    /** Subscribe to host events: tab-changed | workbook-opened | theme-changed. */
    on: on,
    /** Escape hatch for forward-compat: call any host method by name. */
    call: call,
  };
})();
