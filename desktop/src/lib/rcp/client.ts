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
    // Compose the caller's signal with the timeout: a private controller
    // owns the timeout; the caller's signal (if any) chains into it so an
    // abort() upstream cancels the in-flight fetch too. Whichever fires first wins.
    const ctrl = opts.timeoutMs || opts.signal ? new AbortController() : null;
    const timer = ctrl && opts.timeoutMs ? setTimeout(() => ctrl.abort(), opts.timeoutMs) : null;
    const onCallerAbort = () => ctrl?.abort();
    if (ctrl && opts.signal) {
      if (opts.signal.aborted) ctrl.abort();
      else opts.signal.addEventListener("abort", onCallerAbort, { once: true });
    }
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
      if (opts.signal) opts.signal.removeEventListener("abort", onCallerAbort);
    }
  }

  /** Server-Sent-Events over a POST body. EventSource is GET-only, but the
   *  nexus stream route (`/api/run/stream`) needs a JSON body, so we POST and
   *  read `response.body` as a reader. Same auth/base-url/error handling as
   *  `request()`. Splits the chunked stream on blank lines, parses each
   *  `data: <json>` frame, and calls `onEvent(parsed)` per frame. Resolves on
   *  a `{type:"end"}` frame or when the stream closes; rejects (RcpError) on a
   *  failed connect or non-2xx. Composes the caller's `signal`. */
  async stream(
    path: string,
    opts: { method?: string; body?: unknown; signal?: AbortSignal } = {},
    onEvent: (ev: unknown) => void,
  ): Promise<void> {
    const base = this.#base();
    const token = await this.#target.auth.getToken();
    const hasBody = opts.body !== undefined;
    const res = await this.#fetch(`${base}${path}`, {
      method: opts.method ?? "POST",
      headers: {
        accept: "text/event-stream",
        ...(hasBody ? { "content-type": "application/json" } : {}),
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: hasBody ? JSON.stringify(opts.body) : undefined,
      signal: opts.signal,
    });
    if (!res.ok || !res.body) {
      const data = (await res.json().catch(() => null)) as Record<string, unknown> | null;
      throw this.#envelopeError(data, res.status);
    }
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        buf += decoder.decode(value, { stream: true });
        // SSE frames are separated by a blank line.
        let sep: number;
        while ((sep = buf.indexOf("\n\n")) !== -1) {
          const frame = buf.slice(0, sep);
          buf = buf.slice(sep + 2);
          for (const line of frame.split("\n")) {
            if (!line.startsWith("data:")) continue;
            const json = line.slice(5).trim();
            if (!json) continue;
            let parsed: unknown;
            try {
              parsed = JSON.parse(json);
            } catch {
              continue;
            }
            onEvent(parsed);
            if (typeof parsed === "object" && parsed !== null && (parsed as { type?: string }).type === "end") {
              return;
            }
          }
        }
      }
    } catch (e) {
      // An abort throws here — surface as unavailable like #fetch does.
      if (opts.signal?.aborted) return;
      throw new RcpError("unavailable", e instanceof Error ? e.message : "stream error", { retryable: true });
    } finally {
      reader.releaseLock();
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
