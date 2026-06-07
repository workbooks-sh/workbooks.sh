// Authenticated vendor endpoints. Each one is a thin wrapper around the
// vendor-specific helper in this dir — auth, tenant scoping, and request
// shape live here, not in the helper.

import { type Context, Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";
import { RateLimitedError } from "../vendor.js";
import type { FetchBrandOptions, FetchTier } from "./fetch-brand.js";
import { fetchBrand } from "./fetch-brand.js";
import { firecrawlScrape } from "./firecrawl.js";
import { valyuSearch } from "./valyu.js";

const scrape = new Hono<{ Bindings: Bindings }>();
scrape.use("*", requireBearer);

// General WEB RESEARCH via Valyu /v1/search. Exposed at both POST /search
// (canonical) and POST /exa (legacy alias kept for back-compat). Ad
// intelligence does NOT route here — see ads.search / ScrapeCreators.
const webSearchHandler = async (c: Context<{ Bindings: Bindings }>) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    query?: string;
    numResults?: number;
  };
  if (!body.query) {
    return c.json({ error: "missing_query" }, 400);
  }
  const user = c.get("user");
  try {
    const result = await valyuSearch(c.env, {
      query: body.query,
      numResults: body.numResults,
      tenant: user.id,
      ctx: c.executionCtx,
    });
    return c.json(result);
  } catch (e) {
    if (e instanceof RateLimitedError) {
      return c.json({ error: "rate_limited", retry_after: 60 }, 429);
    }
    return c.json({ error: "vendor_error", message: (e as Error).message }, 502);
  }
};

scrape.post("/search", webSearchHandler);
scrape.post("/exa", webSearchHandler);

scrape.post("/firecrawl", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    url?: string;
    formats?: Array<"markdown" | "html" | "rawHtml" | "links" | "screenshot">;
    onlyMainContent?: boolean;
  };
  if (!body.url) {
    return c.json({ error: "missing_url" }, 400);
  }
  const user = c.get("user");
  try {
    const result = await firecrawlScrape(c.env, {
      url: body.url,
      formats: body.formats,
      onlyMainContent: body.onlyMainContent,
      tenant: user.id,
      ctx: c.executionCtx,
    });
    return c.json(result);
  } catch (e) {
    if (e instanceof RateLimitedError) {
      return c.json({ error: "rate_limited", retry_after: 60 }, 429);
    }
    return c.json({ error: "vendor_error", message: (e as Error).message }, 502);
  }
});

// POST /scrape — generic tiered fetcher.
// Body: { url: string, expect?: "html" | "image" | "css" | "any", skipTiers?: FetchTier[] }
// Returns: FetchResult (ok, body, contentType, source, status, fetch_ms, attempts[])
scrape.post("/", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    url?: string;
    expect?: FetchBrandOptions["expect"];
    skipTiers?: FetchTier[];
  };
  if (!body.url) {
    return c.json({ error: "missing_url" }, 400);
  }
  try {
    new URL(body.url);
  } catch {
    return c.json({ error: "invalid_url" }, 400);
  }

  const result = await fetchBrand(c.env, body.url, {
    expect: body.expect,
    skipTiers: body.skipTiers,
  });

  // Binary buffer is not JSON-serialisable; base64-encode it if present.
  if (result.buffer) {
    const bytes = new Uint8Array(result.buffer);
    const b64 = btoa(String.fromCharCode(...bytes));
    return c.json({ ...result, buffer: undefined, buffer_b64: b64 });
  }

  return c.json(result);
});

export default scrape;
