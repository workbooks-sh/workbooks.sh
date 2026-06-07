// fetchBrand() — tiered fetch primitive for brand assets.
//
// Tier sequence (first success wins):
//   1. direct       — plain fetch() with realistic browserHeaders() (shared
//                     current-Chrome UA + Sec-Fetch fingerprint), 5s cap.
//                     Skips on 403 | 429 | 503 or timeout.
//   2. cf-browser   — Cloudflare Workers Browser Rendering via scrape/browser.ts
//                     renderPage() (env.BROWSER). Full headless Chromium; solves
//                     JS challenges. Fails SOFT so we escalate to context-dev.
//   3. context-dev  — POST https://api.context.dev/v1/scrape. 8s cap.
//   4. firecrawl    — POST https://api.firecrawl.dev/v1/scrape. 10s cap.
//
// Each attempt is logged to console.  The returned FetchResult includes
// the full attempts[] array so callers can surface which tier won.

import type { Bindings } from "../env.js";
import { browserHeaders } from "./headers.js";
import { renderPage } from "./browser.js";

// ── Public types ─────────────────────────────────────────────────────────────

export type FetchTier = "direct" | "cf-browser" | "context-dev" | "firecrawl" | "exa-fallback";

export interface FetchAttempt {
  tier: FetchTier;
  status: number;
  ms: number;
  error?: string;
}

export interface FetchResult {
  ok: boolean;
  /** Text content — HTML, CSS, SVG text. */
  body?: string;
  /** Binary content — images, fonts. */
  buffer?: ArrayBuffer;
  contentType?: string;
  source: FetchTier;
  status: number;
  fetch_ms: number;
  attempts: FetchAttempt[];
}

export interface FetchBrandOptions {
  /** Per-tier timeout in milliseconds. Default 5000 for direct, tier-specific otherwise. */
  timeoutMs?: number;
  /** Skip specific tiers (for testing). */
  skipTiers?: FetchTier[];
  /** Hint about expected content type — used to decide whether to read body vs buffer. */
  expect?: "html" | "image" | "css" | "any";
}

// HTTP status codes that signal WAF / rate-limit; skip to next tier.
const WAF_STATUSES = new Set([403, 429, 503]);

// ── Helpers ──────────────────────────────────────────────────────────────────

function timedFetch(url: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  return fetch(url, { ...init, signal: controller.signal }).finally(() =>
    clearTimeout(timer),
  );
}

async function bodyForExpect(
  res: Response,
  expect: FetchBrandOptions["expect"],
): Promise<{ body?: string; buffer?: ArrayBuffer }> {
  if (expect === "image") {
    const buffer = await res.arrayBuffer();
    return { buffer };
  }
  const body = await res.text();
  return { body };
}

// ── Tier 1: direct ───────────────────────────────────────────────────────────

async function tierDirect(
  url: string,
  timeoutMs: number,
  expect: FetchBrandOptions["expect"],
): Promise<{ res?: Response; body?: string; buffer?: ArrayBuffer; error?: string; status: number }> {
  try {
    const res = await timedFetch(
      url,
      {
        headers: browserHeaders(
          expect === "image"
            ? {
                accept: "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
                "sec-fetch-dest": "image",
                "sec-fetch-mode": "no-cors",
              }
            : undefined,
        ),
      },
      timeoutMs,
    );
    if (WAF_STATUSES.has(res.status)) {
      return { status: res.status, error: `waf_blocked:${res.status}` };
    }
    if (!res.ok) {
      return { status: res.status, error: `http_error:${res.status}` };
    }
    const { body, buffer } = await bodyForExpect(res, expect);
    return { status: res.status, body, buffer };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const isTimeout = msg.includes("abort") || msg.includes("timeout");
    return { status: 0, error: isTimeout ? "timeout" : `fetch_error:${msg}` };
  }
}

// ── Tier 2: cf-browser ────────────────────────────────────────────────────────

async function tierCfBrowser(
  env: Bindings,
  url: string,
  timeoutMs: number,
  expect: FetchBrandOptions["expect"],
): Promise<{ body?: string; buffer?: ArrayBuffer; status: number; error?: string }> {
  if (!env.BROWSER) {
    return { status: 0, error: "browser_binding_missing" };
  }

  // For images we can't post-render meaningful bytes through a page render, so
  // we re-attempt the binary fetch with realistic browser headers. Many image
  // CDNs gate on User-Agent / Sec-Fetch, which browserHeaders() satisfies. If
  // that still fails we leave it to the next tier (firecrawl).
  if (expect === "image") {
    try {
      const res = await timedFetch(
        url,
        {
          headers: browserHeaders({
            accept: "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
            "sec-fetch-dest": "image",
            "sec-fetch-mode": "no-cors",
          }),
        },
        Math.max(timeoutMs, 10_000),
      );
      if (!res.ok) return { status: res.status, error: `http_error:${res.status}` };
      const buffer = await res.arrayBuffer();
      return { status: res.status, buffer };
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      return { status: 0, error: `browser_image_error:${msg}` };
    }
  }

  // HTML: route through the shared CF Browser Rendering tier (scrape/browser.ts).
  // renderPage fails SOFT (ok:false) so we surface its error and the caller
  // escalates to context-dev / firecrawl.
  const r = await renderPage(env, url, { waitMs: 0 });
  if (r.ok && r.html !== undefined) {
    return { status: r.status ?? 200, body: r.html };
  }
  return { status: r.status ?? 0, error: r.error ?? "browser_render_failed" };
}

// ── Tier 3: context-dev ──────────────────────────────────────────────────────
//
// Uses GET /v1/scrape/html?url=<url> — context.dev's raw HTML endpoint with
// automatic proxy escalation.  Docs: https://docs.context.dev/llms.txt
// Path: /scrape/html (GET with url query param).

interface ContextScrapeHtmlResponse {
  status?: string;
  html?: string;
  content?: string;
  error?: string;
}

async function tierContextDev(
  env: Bindings,
  url: string,
  timeoutMs: number,
): Promise<{ body?: string; status: number; error?: string }> {
  if (!env.CONTEXT_DEV_API_KEY) {
    return { status: 0, error: "context_dev_key_missing" };
  }
  try {
    const endpoint = new URL("https://api.context.dev/v1/scrape/html");
    endpoint.searchParams.set("url", url);

    const res = await timedFetch(
      endpoint.toString(),
      {
        method: "GET",
        headers: {
          authorization: `Bearer ${env.CONTEXT_DEV_API_KEY}`,
          accept: "application/json",
        },
      },
      timeoutMs,
    );
    if (!res.ok) {
      return { status: res.status, error: `context_dev_error:${res.status}` };
    }
    const data = (await res.json()) as ContextScrapeHtmlResponse;
    const body = data.html ?? data.content;
    if (!body) {
      return { status: res.status, error: "context_dev_empty_body" };
    }
    return { status: res.status, body };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const isTimeout = msg.includes("abort") || msg.includes("timeout");
    return { status: 0, error: isTimeout ? "timeout" : `context_dev_fetch_error:${msg}` };
  }
}

// ── Tier 4: firecrawl ────────────────────────────────────────────────────────

interface FirecrawlScrapeResponse {
  success?: boolean;
  data?: {
    html?: string;
    rawHtml?: string;
    markdown?: string;
  };
  error?: string;
}

async function tierFirecrawl(
  env: Bindings,
  url: string,
  timeoutMs: number,
): Promise<{ body?: string; status: number; error?: string }> {
  if (!env.FIRECRAWL_API_KEY) {
    return { status: 0, error: "firecrawl_key_missing" };
  }
  try {
    const res = await timedFetch(
      "https://api.firecrawl.dev/v1/scrape",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          authorization: `Bearer ${env.FIRECRAWL_API_KEY}`,
        },
        body: JSON.stringify({
          url,
          formats: ["html"],
          onlyMainContent: false,
        }),
      },
      timeoutMs,
    );
    if (!res.ok) {
      return { status: res.status, error: `firecrawl_error:${res.status}` };
    }
    const data = (await res.json()) as FirecrawlScrapeResponse;
    const body = data.data?.html ?? data.data?.rawHtml ?? data.data?.markdown;
    if (!body) {
      return { status: res.status, error: "firecrawl_empty_body" };
    }
    return { status: res.status, body };
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    const isTimeout = msg.includes("abort") || msg.includes("timeout");
    return { status: 0, error: isTimeout ? "timeout" : `firecrawl_fetch_error:${msg}` };
  }
}

// ── Public API ───────────────────────────────────────────────────────────────

/**
 * Tiered brand asset fetcher.
 *
 * Tries up to four tiers in sequence and returns on the first success:
 *
 * 1. **direct** — plain `fetch()` with a Chrome 124 UA. Free, zero latency.
 *    Skipped on 403/429/503 (WAF/rate-limit) or timeout.
 * 2. **cf-browser** — Cloudflare Workers Browser Rendering (`env.BROWSER`).
 *    Full headless Chromium; solves JS challenges and Cloudflare-protected pages.
 * 3. **context-dev** — `POST https://api.context.dev/v1/scrape`. Paid;
 *    ~$0.001/call. Covers WAF-protected pages with managed infrastructure.
 * 4. **firecrawl** — `POST https://api.firecrawl.dev/v1/scrape`. Paid;
 *    ~$0.002/call. Last-resort fallback for heavy anti-bot pages.
 *
 * @param env  Cloudflare Worker bindings (needs BROWSER, CONTEXT_DEV_API_KEY, FIRECRAWL_API_KEY)
 * @param url  Absolute URL to fetch
 * @param opts Per-tier timeout, tier skip list, and content-type hint
 */
export async function fetchBrand(
  env: Bindings,
  url: string,
  opts: FetchBrandOptions = {},
): Promise<FetchResult> {
  const {
    timeoutMs = 5000,
    skipTiers = [],
    expect = "any",
  } = opts;

  const skip = new Set<FetchTier>(skipTiers);
  const attempts: FetchAttempt[] = [];
  const overallT0 = Date.now();

  // ── Tier 1: direct ──────────────────────────────────────────────────────
  if (!skip.has("direct")) {
    const t0 = Date.now();
    const result = await tierDirect(url, timeoutMs, expect);
    const ms = Date.now() - t0;
    const attempt: FetchAttempt = { tier: "direct", status: result.status, ms };
    if (result.error) attempt.error = result.error;
    attempts.push(attempt);
    console.log(`[fetchBrand] direct ${url} → ${result.status} (${ms}ms)${result.error ? ` err=${result.error}` : ""}`);

    if (result.body !== undefined || result.buffer !== undefined) {
      return {
        ok: true,
        body: result.body,
        buffer: result.buffer,
        source: "direct",
        status: result.status,
        fetch_ms: Date.now() - overallT0,
        attempts,
      };
    }
  }

  // ── Tier 2: cf-browser ──────────────────────────────────────────────────
  if (!skip.has("cf-browser")) {
    const t0 = Date.now();
    const result = await tierCfBrowser(env, url, 15_000, expect);
    const ms = Date.now() - t0;
    const attempt: FetchAttempt = { tier: "cf-browser", status: result.status, ms };
    if (result.error) attempt.error = result.error;
    attempts.push(attempt);
    console.log(`[fetchBrand] cf-browser ${url} → ${result.status} (${ms}ms)${result.error ? ` err=${result.error}` : ""}`);

    if (result.body !== undefined || result.buffer !== undefined) {
      return {
        ok: true,
        body: result.body,
        buffer: result.buffer,
        source: "cf-browser",
        status: result.status,
        fetch_ms: Date.now() - overallT0,
        attempts,
      };
    }
  }

  // ── Tier 3: context-dev ─────────────────────────────────────────────────
  if (!skip.has("context-dev")) {
    const t0 = Date.now();
    const result = await tierContextDev(env, url, 8_000);
    const ms = Date.now() - t0;
    const attempt: FetchAttempt = { tier: "context-dev", status: result.status, ms };
    if (result.error) attempt.error = result.error;
    attempts.push(attempt);
    console.log(`[fetchBrand] context-dev ${url} → ${result.status} (${ms}ms)${result.error ? ` err=${result.error}` : ""}`);

    if (result.body !== undefined) {
      return {
        ok: true,
        body: result.body,
        source: "context-dev",
        status: result.status,
        fetch_ms: Date.now() - overallT0,
        attempts,
      };
    }
  }

  // ── Tier 4: firecrawl ───────────────────────────────────────────────────
  if (!skip.has("firecrawl")) {
    const t0 = Date.now();
    const result = await tierFirecrawl(env, url, 10_000);
    const ms = Date.now() - t0;
    const attempt: FetchAttempt = { tier: "firecrawl", status: result.status, ms };
    if (result.error) attempt.error = result.error;
    attempts.push(attempt);
    console.log(`[fetchBrand] firecrawl ${url} → ${result.status} (${ms}ms)${result.error ? ` err=${result.error}` : ""}`);

    if (result.body !== undefined) {
      return {
        ok: true,
        body: result.body,
        source: "firecrawl",
        status: result.status,
        fetch_ms: Date.now() - overallT0,
        attempts,
      };
    }
  }

  // All tiers failed.
  return {
    ok: false,
    source: "direct",
    status: attempts[attempts.length - 1]?.status ?? 0,
    fetch_ms: Date.now() - overallT0,
    attempts,
  };
}
