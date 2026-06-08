// RCP client — the one transport (§3). PORTABLE (no Tauri/Svelte imports).
//
//   const rcp = new RcpClient(target);
//   const caps = await rcp.capabilities();      // GET /.well-known (public)
//   const out  = await rcp.request("/api/...", { body });   // unary, Bearer-authed
//   const sock = rcp.socket("/w/:id/ws", { onMessage });    // streaming
//
// Every failure becomes an RcpError; a down/unreachable runtime → code
// "unavailable" (retryable) so callers degrade with one check (e.isUnavailable).

import { RcpError, type RcpCapabilities, type RcpRequestOptions, type RcpTarget } from "./types";

const WELL_KNOWN = "/.well-known/workbooks-runtime";

export class RcpClient {
  #target: RcpTarget;
  #caps: RcpCapabilities | null = null;

  constructor(target: RcpTarget) {
    this.#target = target;
  }

  /** Fetch (and cache) the capabilities handshake. Public — no credential. */
  async capabilities(force = false): Promise<RcpCapabilities> {
    if (this.#caps && !force) return this.#caps;
    const base = this.#base();
    const res = await this.#fetch(`${base}${WELL_KNOWN}`, { method: "GET", headers: { accept: "application/json" } });
    const doc = (await res.json().catch(() => null)) as RcpCapabilities | null;
    if (!res.ok || !doc) throw new RcpError("unavailable", "no capabilities handshake", { status: res.status });
    this.#caps = doc;
    return doc;
  }

  /** Unary request/response. Attaches the Bearer credential from the auth
   *  adapter (fixes the old gap where REST calls sent no token). */
  async request<T = unknown>(path: string, opts: RcpRequestOptions = {}): Promise<T> {
    const base = this.#base();
    const token = await this.#target.auth.getToken();
    const hasBody = opts.bodyText !== undefined || opts.body !== undefined;
    const ctrl = opts.timeoutMs ? new AbortController() : null;
    const timer = ctrl ? setTimeout(() => ctrl.abort(), opts.timeoutMs) : null;
    try {
      const res = await this.#fetch(`${base}${path}${opts.query ?? ""}`, {
        method: opts.method ?? (hasBody ? "POST" : "GET"),
        headers: {
          accept: "application/json",
          ...(hasBody ? { "content-type": opts.contentType ?? "application/json" } : {}),
          ...(token ? { authorization: `Bearer ${token}` } : {}),
        },
        body: opts.bodyText ?? (opts.body !== undefined ? JSON.stringify(opts.body) : undefined),
        signal: ctrl?.signal,
      });
      const data = (await res.json().catch(() => null)) as Record<string, unknown> | null;
      if (!res.ok) throw this.#envelopeError(data, res.status);
      return data as T;
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  /** Open a streaming WebSocket. First frame carries the credential per §3. */
  socket(path: string, handlers: { onMessage?: (data: unknown) => void; onClose?: () => void; onError?: (e: unknown) => void } = {}): WebSocket {
    const base = this.#base();
    const wsUrl = base.replace(/^http/, "ws") + path;
    const ws = new WebSocket(wsUrl);
    ws.addEventListener("open", async () => {
      const token = await this.#target.auth.getToken();
      if (token) ws.send(JSON.stringify({ auth: token }));
    });
    if (handlers.onMessage)
      ws.addEventListener("message", (e) => {
        let parsed: unknown = e.data;
        try {
          parsed = JSON.parse(e.data as string);
        } catch {
          /* leave raw */
        }
        handlers.onMessage!(parsed);
      });
    if (handlers.onClose) ws.addEventListener("close", () => handlers.onClose!());
    if (handlers.onError) ws.addEventListener("error", (e) => handlers.onError!(e));
    return ws;
  }

  // ---- internals ----
  #base(): string {
    const b = this.#target.getBaseUrl();
    if (!b) throw new RcpError("unavailable", "runtime not reachable (no base url)", { retryable: true });
    return b;
  }

  /** fetch wrapper: any network/abort failure → RcpError("unavailable"). */
  async #fetch(url: string, init: RequestInit): Promise<Response> {
    try {
      return await fetch(url, init);
    } catch (e) {
      throw new RcpError("unavailable", e instanceof Error ? e.message : "network error", { retryable: true });
    }
  }

  /** Map the §4 envelope { error: { code, message, retryable } } → RcpError. */
  #envelopeError(data: Record<string, unknown> | null, status: number): RcpError {
    const env = (data?.error ?? null) as { code?: string; message?: string; retryable?: boolean } | null;
    if (env?.code) {
      return new RcpError(env.code, env.message ?? env.code, { retryable: env.retryable, status });
    }
    // Legacy/non-enveloped failure.
    return new RcpError(`http_${status}`, `HTTP ${status}`, { status });
  }
}
