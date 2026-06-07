// Firecrawl wrapper. Used when Cloudflare Browser Rendering can't get
// a page (heavy anti-bot, complex auth, etc.) and we need the rendered
// DOM as markdown or structured JSON.
//
// Docs: https://docs.firecrawl.dev
// Auth: Bearer token in env.FIRECRAWL_API_KEY.

import type { Bindings } from "../env.js";
import { vendorFetch } from "../vendor.js";

const BASE = "https://api.firecrawl.dev";

export interface FirecrawlScrapeOptions {
  url: string;
  formats?: Array<"markdown" | "html" | "rawHtml" | "links" | "screenshot">;
  onlyMainContent?: boolean;
  /** Per-tenant cache namespacing. */
  tenant: string;
  ctx?: ExecutionContext;
}

export interface FirecrawlScrapeResult {
  success: boolean;
  data?: {
    markdown?: string;
    html?: string;
    rawHtml?: string;
    links?: string[];
    metadata?: Record<string, unknown>;
  };
  error?: string;
}

export async function firecrawlScrape(
  env: Bindings,
  opts: FirecrawlScrapeOptions,
): Promise<FirecrawlScrapeResult> {
  if (!env.FIRECRAWL_API_KEY) {
    throw new Error("FIRECRAWL_API_KEY is not configured on the worker");
  }
  const body = JSON.stringify({
    url: opts.url,
    formats: opts.formats ?? ["markdown"],
    onlyMainContent: opts.onlyMainContent ?? true,
  });
  const res = await vendorFetch(env, {
    provider: "firecrawl",
    tenant: opts.tenant,
    url: `${BASE}/v1/scrape`,
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${env.FIRECRAWL_API_KEY}`,
    },
    body,
    cacheTtl: 3600,
    rateLimit: 20,
    metadata: { url: opts.url },
    ctx: opts.ctx,
  });
  if (!res.ok) {
    throw new Error(`Firecrawl scrape ${res.status}: ${await res.text()}`);
  }
  return (await res.json()) as FirecrawlScrapeResult;
}
