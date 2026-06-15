// The Host/Dock seam — one capability surface for every element.
//
// A workponent never hardcodes where a capability runs. It asks the Host, which
// resolves `local` (in-WASM / browser-native), `runtime` (a Workbooks runtime
// over RCP), or `kernel` (oql.wasm) per the platform-model — so the SAME element
// (e.g. <wb-table>) runs in-WASM locally or on the runtime tier for huge data,
// no code fork. Capability elements declare what they need; the Host provisions
// it (the same grant model toolkits use) and reports availability so the element
// degrades cleanly when a capability is absent (e.g. voice without a key).
//
// Phase 0: a minimal, portable seam (no Tauri/Svelte). When a runtime URL is
// configured it routes over fetch/WebSocket (mirroring desktop/src/lib/rcp);
// otherwise it serves local capabilities and reports the rest unavailable.

let _host = null;

export class WbHost {
  /** @param {{ runtimeUrl?: string|null, tenant?: string }} [opts] */
  constructor(opts = {}) {
    this.runtimeUrl = opts.runtimeUrl || null;
    this.tenant = opts.tenant || "local";
    this._caps = new Set(["local"]); // in-WASM/browser caps are always present
  }

  /** Is a capability reachable here? (elements gate UI on this) */
  available(cap) {
    return this._caps.has(cap) || (this.runtimeUrl != null && cap !== "voice");
  }

  /** Unary capability call — routed to the runtime when present. */
  async request(path, { method = "POST", body } = {}) {
    if (!this.runtimeUrl) throw new Error(`wb-host: no runtime for ${path}`);
    const res = await fetch(this.runtimeUrl.replace(/\/$/, "") + path, {
      method,
      headers: { "content-type": "application/json", "x-tenant": this.tenant },
      body: body != null ? JSON.stringify(body) : undefined,
    });
    if (!res.ok) throw new Error(`wb-host ${res.status} ${path}`);
    return res.json();
  }

  /** Streaming capability — a WebSocket to the runtime. */
  socket(path, { onMessage } = {}) {
    if (!this.runtimeUrl) throw new Error(`wb-host: no runtime for ${path}`);
    const url = this.runtimeUrl.replace(/^http/, "ws").replace(/\/$/, "") + path;
    const ws = new WebSocket(url);
    if (onMessage) ws.addEventListener("message", (e) => onMessage(e.data));
    return ws;
  }
}

/** Configure the shared Host (call once at app/workbook boot). */
export function configureHost(opts) {
  _host = new WbHost(opts);
  return _host;
}

/** The shared Host singleton (a local-only Host by default). */
export function getHost() {
  if (!_host) {
    // Honor a global hint (a workbook/desktop can set window.__WB_RUNTIME_URL__).
    const url = typeof window !== "undefined" ? window.__WB_RUNTIME_URL__ : null;
    _host = new WbHost({ runtimeUrl: url || null });
  }
  return _host;
}
