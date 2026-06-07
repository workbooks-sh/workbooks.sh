// Non-LLM vendor HTTP wrapper.
//
// AI Gateway (gateway.ts) only proxies LLM upstreams. For non-LLM
// vendors (Exa, Firecrawl, Scrapecreators, logo.dev, Brandfetch, E2B)
// we replicate the same three properties — caching, cost/usage
// visibility, per-tenant rate limiting — using:
//
//   - Cloudflare Cache API (caches.default) for response caching, keyed
//     by provider + tenant + url. Cache hits don't touch the upstream.
//   - vendor_calls + vendor_rate_limit tables in D1 for usage logging
//     and per-tenant rate limiting (sliding window via the rate-limit
//     table). Logged via ctx.waitUntil so they never block responses.
//
// This module intentionally has zero vendor-specific code; per-vendor
// wrappers live in apps/api/src/scrape/* and call vendorFetch.

import type { Bindings } from "./env.js";

export interface VendorFetchOptions {
  /** Stable upstream identifier — e.g. "exa", "firecrawl". Used for
   *  cache namespacing, rate limit buckets, and usage logs. */
  provider: string;
  /** Tenant doing the call. Use the authed user id where available. */
  tenant: string;
  url: string;
  method?: string;
  headers?: Record<string, string>;
  body?: string | ArrayBuffer | null;
  /** Cache TTL in seconds. 0 disables caching. Default 3600. */
  cacheTtl?: number;
  /** Per-tenant per-provider call cap per minute. Default 60. */
  rateLimit?: number;
  /** Extra log metadata (e.g. brand_id). */
  metadata?: Record<string, unknown>;
  /** Skip caching for this call (e.g. POSTs that mutate). */
  bypassCache?: boolean;
  /** Cloudflare Worker execution context — used to fire-and-forget
   *  cache.put + usage logging without blocking the response. */
  ctx?: ExecutionContext;
}

export class RateLimitedError extends Error {
  constructor(
    readonly provider: string,
    readonly tenant: string,
    readonly limit: number,
  ) {
    super(`rate limited: ${tenant} exceeded ${limit}/min for ${provider}`);
    this.name = "RateLimitedError";
  }
}

const RATE_WINDOW_MS = 60_000;

async function cacheKeyFor(opts: VendorFetchOptions): Promise<Request> {
  // Cache key encodes provider + tenant + method + url + body hash so
  // (a) tenants don't share cached responses, (b) different bodies don't
  // collide.
  const bodyHash = opts.body
    ? await digestHex(typeof opts.body === "string" ? opts.body : new Uint8Array(opts.body))
    : "";
  const synthetic = new URL(
    `https://cache.brandnana.internal/${opts.provider}/${opts.tenant}/${opts.method ?? "GET"}/${bodyHash}`,
  );
  synthetic.searchParams.set("u", opts.url);
  return new Request(synthetic.toString());
}

async function digestHex(input: string | Uint8Array): Promise<string> {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)]
    .slice(0, 12)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function checkRateLimit(
  env: Bindings,
  provider: string,
  tenant: string,
  limit: number,
): Promise<{ ok: boolean; remaining: number }> {
  const windowStart = Math.floor(Date.now() / RATE_WINDOW_MS) * RATE_WINDOW_MS;
  const row = await env.DB.prepare(
    `INSERT INTO vendor_rate_limit (tenant, provider, window_start, count)
     VALUES (?, ?, ?, 1)
     ON CONFLICT(tenant, provider, window_start) DO UPDATE SET count = count + 1
     RETURNING count`,
  )
    .bind(tenant, provider, windowStart)
    .first<{ count: number }>();
  const count = row?.count ?? 1;
  return { ok: count <= limit, remaining: Math.max(0, limit - count) };
}

interface CallLog {
  provider: string;
  tenant: string;
  url: string;
  status: number;
  cache: "hit" | "miss" | "bypass";
  bytes: number;
  duration_ms: number;
  metadata: string | null;
}

async function logCall(env: Bindings, log: CallLog): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO vendor_calls
       (id, provider, tenant, url, status, cache_state, bytes, duration_ms, metadata, called_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      crypto.randomUUID(),
      log.provider,
      log.tenant,
      log.url,
      log.status,
      log.cache,
      log.bytes,
      log.duration_ms,
      log.metadata,
      Date.now(),
    )
    .run()
    .catch(() => undefined);
}

/**
 * Fetch a non-LLM vendor through the cache + rate-limit layer. The
 * response is the upstream response (possibly served from cache).
 *
 * Throws RateLimitedError if the tenant has exceeded its cap.
 */
export async function vendorFetch(env: Bindings, opts: VendorFetchOptions): Promise<Response> {
  const t0 = Date.now();
  const cacheTtl = opts.cacheTtl ?? 3600;
  const limit = opts.rateLimit ?? 60;
  const cache = caches.default;

  // Cache check. Synthetic cache key includes method + body hash so
  // POSTs to the same URL with different payloads don't collide.
  // Caller opts out of caching for mutating calls via bypassCache.
  const method = opts.method ?? "GET";
  const cacheable = !opts.bypassCache && cacheTtl > 0;
  let cacheKey: Request | undefined;
  if (cacheable) {
    cacheKey = await cacheKeyFor(opts);
    const hit = await cache.match(cacheKey);
    if (hit) {
      const cloned = hit.clone();
      const bytes = Number(hit.headers.get("content-length") ?? 0);
      const log = (): Promise<void> =>
        logCall(env, {
          provider: opts.provider,
          tenant: opts.tenant,
          url: opts.url,
          status: hit.status,
          cache: "hit",
          bytes,
          duration_ms: Date.now() - t0,
          metadata: opts.metadata ? JSON.stringify(opts.metadata) : null,
        });
      if (opts.ctx) opts.ctx.waitUntil(log());
      else await log();
      return cloned;
    }
  }

  // Rate limit (counts every upstream call, not cache hits).
  const rl = await checkRateLimit(env, opts.provider, opts.tenant, limit);
  if (!rl.ok) {
    throw new RateLimitedError(opts.provider, opts.tenant, limit);
  }

  // Upstream call.
  const upstream = await fetch(opts.url, {
    method,
    headers: opts.headers,
    body: opts.body ?? undefined,
  });

  // Cache store (clone so we still return a usable body).
  if (cacheable && cacheKey && upstream.ok) {
    const toCache = upstream.clone();
    const headers = new Headers(toCache.headers);
    headers.set("cache-control", `public, max-age=${cacheTtl}`);
    const cached = new Response(toCache.body, {
      status: toCache.status,
      statusText: toCache.statusText,
      headers,
    });
    const put = cache.put(cacheKey, cached);
    if (opts.ctx) opts.ctx.waitUntil(put);
    else await put;
  }

  const bytes = Number(upstream.headers.get("content-length") ?? 0);
  const log = (): Promise<void> =>
    logCall(env, {
      provider: opts.provider,
      tenant: opts.tenant,
      url: opts.url,
      status: upstream.status,
      cache: opts.bypassCache ? "bypass" : "miss",
      bytes,
      duration_ms: Date.now() - t0,
      metadata: opts.metadata ? JSON.stringify(opts.metadata) : null,
    });
  if (opts.ctx) opts.ctx.waitUntil(log());
  else await log();

  return upstream;
}
