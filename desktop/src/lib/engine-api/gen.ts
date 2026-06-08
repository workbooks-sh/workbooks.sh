// Hand-written replacement for the formerly-generated engine client.
//
// The old generator (scripts/gen-engine-api.mjs) compiled this file from
// runtime/engine/priv/api-verbs.json — a schema that no longer exists (the
// runtime was rewritten; the desktop now talks to the runtime control-plane
// over the discovered {url, token}). The transport below is the same shape the
// generator emitted (sidecar guard → fetch → JSON → EngineApiError); the verb
// maps are resolved dynamically since the static schema is gone. Most callers
// pass literal paths to engineRequest; the few enginePath.* refs derive a path
// from the verb name. Real per-verb wiring is reconciled in Phase B.

import { sidecar } from "$lib/bridge/sidecar.svelte";

/** The one engine API error. Every engine-facing module throws this shape. */
export class EngineApiError extends Error {
  code: string;
  status: number;
  constructor(code: string, message: string, status: number) {
    super(message);
    this.name = "EngineApiError";
    this.code = code;
    this.status = status;
  }
}

export interface EngineRequestOptions {
  method?: string;
  /** Pre-built query string, starting with "?". */
  query?: string;
  /** JSON-encoded request body. */
  body?: unknown;
  /** Raw request body (overrides `body`); pair with `contentType`. */
  bodyText?: string;
  contentType?: string;
  timeoutMs?: number;
}

/** The one transport for engine calls: sidecar guard, optional timeout, JSON
 *  decode, and normalization of every failure to EngineApiError. */
export async function engineRequest<T = unknown>(
  path: string,
  opts: EngineRequestOptions = {},
): Promise<T> {
  const base = sidecar.status.url;
  if (!base) {
    throw new EngineApiError("sidecar_down", "Agent server isn't running.", 0);
  }
  const ctrl = opts.timeoutMs ? new AbortController() : null;
  const timer = ctrl ? setTimeout(() => ctrl.abort(), opts.timeoutMs) : null;
  try {
    const hasBody = opts.bodyText !== undefined || opts.body !== undefined;
    const res = await fetch(`${base}${path}${opts.query ?? ""}`, {
      method: opts.method ?? (hasBody ? "POST" : "GET"),
      headers: {
        accept: "application/json",
        ...(hasBody ? { "content-type": opts.contentType ?? "application/json" } : {}),
      },
      body: opts.bodyText ?? (opts.body !== undefined ? JSON.stringify(opts.body) : undefined),
      signal: ctrl?.signal,
    });
    const data = (await res.json().catch(() => null)) as {
      error?: unknown;
      message?: unknown;
    } | null;
    if (!res.ok) {
      throw new EngineApiError(
        typeof data?.error === "string" ? data.error : `http_${res.status}`,
        typeof data?.message === "string" ? data.message : `HTTP ${res.status}`,
        res.status,
      );
    }
    return data as T;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/** Verb→path. Schema removed; derive `/api/<verb/with/slashes>` from the verb
 *  name. Covers the few enginePath.* refs (agents_list, run); literal-path
 *  callers bypass this entirely. */
export const enginePath: Record<string, string> = new Proxy(
  {},
  { get: (_t, key) => "/api/" + String(key).replace(/_/g, "/") },
) as Record<string, string>;

/** Verb→method. Unused directly today (callers set method inline); default GET. */
export const engineMethod: Record<string, string> = new Proxy(
  {},
  { get: () => "GET" },
) as Record<string, string>;
