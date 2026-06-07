// context.dev catalog adapter — used for non-Shopify domains.
//
// POST /v1/brand/ai/products with { domain, maxProducts } returns up
// to 12 products in a single sync call (5-min timeout). Smaller than
// Shopify's full catalog but covers everything else for free without
// us running a Python sandbox.
//
// Cached for 7d per (tenant, domain) via vendor.ts.

import type { Bindings } from "../env.js";
import { vendorFetch } from "../vendor.js";
import type { CatalogRow, ProductImageRow, ProductRow, StatsRow } from "./shopify.js";

interface ContextProduct {
  name?: string;
  description?: string | null;
  price?: number | string | null;
  currency?: string | null;
  url?: string | null;
  image_url?: string | null;
  images?: string[] | null;
  features?: string[] | null;
  sku?: string | null;
  category?: string | null;
}

interface ContextProductsResponse {
  status?: string;
  products?: ContextProduct[];
  error?: { message?: string };
}

function toCents(price: unknown): number | null {
  if (price == null || price === "") return null;
  const n = typeof price === "number" ? price : Number.parseFloat(String(price));
  return Number.isFinite(n) ? Math.round(n * 100) : null;
}

export interface ContextCrawlOptions {
  env: Bindings;
  domain: string;
  brandId: string;
  tenant: string;
  /** Forwarded to context.dev as `maxProducts`. Hard-capped server-side at
   * 12 — passing >12 returns HTTP 400. Anything bigger gets clamped here
   * with a warning emitted into the stats errors[] so callers know why. */
  maxProducts?: number;
  ctx?: ExecutionContext;
}

/** Async generator that yields CatalogRows from context.dev /products. */
export async function* crawlContext(opts: ContextCrawlOptions): AsyncGenerator<CatalogRow> {
  const startedAt = Date.now();
  const errors: string[] = [];
  let products = 0;
  let images = 0;

  if (!opts.env.CONTEXT_DEV_API_KEY) {
    yield {
      __type: "stats",
      source: "context-dev",
      products: 0,
      images: 0,
      pages_fetched: 0,
      errors: ["CONTEXT_DEV_API_KEY not configured"],
      started_at: startedAt,
      finished_at: Date.now(),
    } satisfies StatsRow;
    return;
  }

  if ((opts.maxProducts ?? 0) > 12) {
    errors.push(
      `context.dev hard-caps at 12 products per call (you asked for ${opts.maxProducts}). For larger catalogs on non-Shopify brands, use strategy=llm (LLM-extract path).`,
    );
  }

  let body: ContextProductsResponse;
  try {
    const res = await vendorFetch(opts.env, {
      provider: "context-dev",
      tenant: opts.tenant,
      url: "https://api.context.dev/v1/brand/ai/products",
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: `Bearer ${opts.env.CONTEXT_DEV_API_KEY}`,
      },
      body: JSON.stringify({
        domain: opts.domain.replace(/^https?:\/\//, "").replace(/\/$/, ""),
        maxProducts: Math.min(opts.maxProducts ?? 12, 12),
      }),
      cacheTtl: 86_400 * 7,
      rateLimit: 30,
      metadata: { domain: opts.domain },
      ctx: opts.ctx,
    });
    if (!res.ok) {
      errors.push(`context.dev HTTP ${res.status}`);
      body = {};
    } else {
      body = (await res.json()) as ContextProductsResponse;
    }
  } catch (e) {
    errors.push((e as Error).message);
    body = {};
  }

  if (body.error?.message) errors.push(body.error.message);

  for (const p of body.products ?? []) {
    if (!p.name) continue;
    const now = Date.now();
    const productId = crypto.randomUUID();
    const productRow: ProductRow = {
      __type: "product",
      id: productId,
      brand_id: opts.brandId,
      external_id: p.sku ?? null,
      url: p.url ?? opts.domain,
      title: p.name,
      description: p.description ?? null,
      price_cents: toCents(p.price),
      currency: p.currency ?? null,
      available: 1,
      platform: "context-dev",
      raw_json: JSON.stringify(p),
      first_seen_at: now,
      last_seen_at: now,
    };
    yield productRow;
    products += 1;

    const imgList: string[] = [];
    if (typeof p.image_url === "string" && p.image_url) imgList.push(p.image_url);
    if (Array.isArray(p.images)) {
      for (const i of p.images) {
        if (typeof i === "string" && i && !imgList.includes(i)) imgList.push(i);
      }
    }
    for (let i = 0; i < imgList.length; i++) {
      const url = imgList[i];
      if (!url) continue;
      const row: ProductImageRow = {
        __type: "product_image",
        id: crypto.randomUUID(),
        product_id: productId,
        url,
        alt: null,
        width: null,
        height: null,
        position: i,
      };
      yield row;
      images += 1;
    }
  }

  const stats: StatsRow = {
    __type: "stats",
    source: "context-dev",
    products,
    images,
    pages_fetched: 1,
    errors,
    started_at: startedAt,
    finished_at: Date.now(),
  };
  yield stats;
}
