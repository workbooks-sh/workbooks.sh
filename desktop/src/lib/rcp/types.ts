// RCP — Runtime Connect Protocol client, core types.
// (spec: runtime/docs/RUNTIME-CONNECT-PROTOCOL.org)
//
// PORTABLE: this file (and client.ts / adapters.ts) import NOTHING from Tauri or
// Svelte. The same code runs in a Tauri app, a web app, or a raw .html file with
// only fetch + WebSocket. Tauri-specific discovery lives in providers/.

/** The handshake doc served at GET /.well-known/workbooks-runtime (§1). */
export interface RcpCapabilities {
  rcp: string;
  runtime: string;
  tenancy: "single" | "multi";
  auth: {
    rung: "trusted" | "oidc-jwt";
    issuer: string | null;
    jwks_url: string | null;
  };
  transports: { http: boolean; ws: boolean };
  capabilities: string[];
}

/** The closed error vocabulary every client switches on (§4). */
export type RcpErrorCode =
  | "bad_request"
  | "unauthorized"
  | "tenant_required"
  | "forbidden"
  | "not_found"
  | "unavailable" // runtime down / unreachable — the degrade signal
  | "internal";

/** The one error every RCP call throws. Never parse raw bodies — switch on code. */
export class RcpError extends Error {
  code: RcpErrorCode | string;
  retryable: boolean;
  status: number;
  constructor(code: RcpErrorCode | string, message: string, opts: { retryable?: boolean; status?: number } = {}) {
    super(message);
    this.name = "RcpError";
    this.code = code;
    this.retryable = opts.retryable ?? (code === "unavailable" || code === "internal");
    this.status = opts.status ?? 0;
  }
  /** True when the runtime is down/unreachable — callers degrade gracefully. */
  get isUnavailable(): boolean {
    return this.code === "unavailable";
  }
}

/** Obtains the Bearer credential for the current auth rung. The ONLY thing a
 *  client embedder ever swaps to change IDP (§2). */
export interface AuthAdapter {
  /** null = anonymous (allowed only by single-tenant `trusted` runtimes). */
  getToken(): Promise<string | null>;
}

/** Where the runtime is + how to authenticate to it. A provider (local-tauri,
 *  url, ...) builds this; the client consumes it. */
export interface RcpTarget {
  /** Resolve the base URL (e.g. "http://127.0.0.1:4000"); null = unknown/down. */
  getBaseUrl(): string | null;
  /** The credential source for the required rung. */
  auth: AuthAdapter;
}

export interface RcpRequestOptions {
  method?: string;
  query?: string; // pre-built, starts with "?"
  body?: unknown;
  bodyText?: string;
  contentType?: string;
  timeoutMs?: number;
  /** Caller-owned cancellation. Aborting it aborts the in-flight fetch.
   *  Composes with `timeoutMs` — whichever fires first wins. */
  signal?: AbortSignal;
}
