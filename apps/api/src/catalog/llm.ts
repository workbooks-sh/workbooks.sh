// LLM-extract catalog adapter — last-resort path for sites without
// /products.json or a usable sitemap, when context.dev's extract-products
// also fails. Pipeline:
//
//   1. Firecrawl scrapes the homepage (rendered markdown).
//   2. Llama 3.3 reads the homepage and lists ≤5 likely listing-page URLs.
//   3. Firecrawl scrapes each listing.
//   4. Llama 3.3 extracts product cards from each listing's markdown.
//   5. Yield product + product_image rows + stats.
//
// Used when strategy=llm explicitly, OR as the final rung of the auto
// cascade (shopify → sitemap → llm) when the earlier rungs come back thin.
// Costs ~2-5 LLM calls + 1-6 Firecrawl scrapes per domain; goes through
// vendor.ts so it's cached + rate-limited.

import type { Bindings } from "../env.js";
import { chat } from "../llm/openrouter.js";
import { firecrawlScrape } from "../scrape/firecrawl.js";
import type { CatalogRow, ProductImageRow, ProductRow, StatsRow } from "./shopify.js";

const HIGH_QUALITY_MODEL = "meta-llama/llama-3.3-70b-instruct";

export interface LlmCrawlOptions {
  env: Bindings;
  domain: string;
  brandId: string;
  tenant: string;
  /** Cap on listing pages we visit. */
  maxListings?: number;
  /** Cap on total products yielded. */
  maxProducts?: number;
  ctx?: ExecutionContext;
}

interface ExtractedProduct {
  name: string;
  url?: string;
  description?: string;
  price?: string | number;
  currency?: string;
  image_url?: string;
}

function normalizeOrigin(domain: string): string {
  const raw = domain.trim();
  return raw.includes("://") ? raw : `https://${raw}`;
}

function toCents(price: unknown): number | null {
  if (price == null || price === "") return null;
  if (typeof price === "number") return Math.round(price * 100);
  const s = String(price)
    .replace(/[^\d.,]/g, "")
    .replace(",", ".");
  const n = Number.parseFloat(s);
  return Number.isFinite(n) ? Math.round(n * 100) : null;
}

function safeJsonParse<T>(s: string): T | null {
  // LLMs sometimes wrap JSON in markdown fences. Strip them.
  const cleaned = s
    .trim()
    .replace(/^```(?:json)?\s*\n?/i, "")
    .replace(/\n?```\s*$/i, "")
    .trim();
  try {
    return JSON.parse(cleaned) as T;
  } catch {
    // Try extracting the first {...} or [...] block.
    const m = /[\[{][\s\S]*[\]}]/.exec(cleaned);
    if (!m) return null;
    try {
      return JSON.parse(m[0]) as T;
    } catch {
      return null;
    }
  }
}

async function listingUrlsFromHomepage(
  env: Bindings,
  origin: string,
  homepage: string,
  tenant: string,
): Promise<string[]> {
  const truncated = homepage.slice(0, 12000);
  const res = await chat(env, {
    tenant,
    model: HIGH_QUALITY_MODEL,
    max_tokens: 400,
    response_format: { type: "json_object" },
    messages: [
      {
        role: "system",
        content:
          "You are extracting URLs from a website homepage. Return ONLY valid JSON. " +
          "No explanations, no markdown fences, just the JSON object.",
      },
      {
        role: "user",
        content: [
          `Site: ${origin}`,
          "",
          "Homepage markdown (truncated):",
          truncated,
          "",
          "Find up to 5 URLs on this site that are LIKELY product listing or category pages",
          "(e.g. /collections/all, /shop, /products, /catalog). Skip blog/about/contact/login pages.",
          'Return JSON: {"listings": [{"url": "https://…", "reason": "why"}]}.',
          "URLs must be absolute (prefix with the site origin if needed).",
        ].join("\n"),
      },
    ],
  });
  const parsed = safeJsonParse<{ listings?: Array<{ url?: string }> }>(res.content);
  const urls = (parsed?.listings ?? [])
    .map((l) => l.url)
    .filter((u): u is string => typeof u === "string" && /^https?:\/\//.test(u))
    .slice(0, 5);
  return urls;
}

async function productsFromListing(
  env: Bindings,
  listing: string,
  listingMd: string,
  tenant: string,
): Promise<ExtractedProduct[]> {
  const truncated = listingMd.slice(0, 16000);
  const res = await chat(env, {
    tenant,
    model: HIGH_QUALITY_MODEL,
    max_tokens: 1500,
    response_format: { type: "json_object" },
    messages: [
      {
        role: "system",
        content:
          "You extract product cards from listing-page markdown. Return ONLY valid JSON. " +
          "No prose, no markdown fences.",
      },
      {
        role: "user",
        content: [
          `Listing URL: ${listing}`,
          "",
          "Markdown:",
          truncated,
          "",
          "Extract every product on this page. For each, capture name (required), URL (absolute),",
          "description (1 sentence), price (number, no currency symbol), currency (ISO code like USD),",
          "image_url (absolute). Skip nav/footer/promo items.",
          'Return JSON: {"products": [{"name": "...", "url": "...", "price": 19.99, "currency": "USD", "image_url": "..."}]}',
        ].join("\n"),
      },
    ],
  });
  const parsed = safeJsonParse<{ products?: ExtractedProduct[] }>(res.content);
  return (parsed?.products ?? []).filter(
    (p): p is ExtractedProduct => typeof p?.name === "string" && p.name.length > 0,
  );
}

export async function* crawlLlm(opts: LlmCrawlOptions): AsyncGenerator<CatalogRow> {
  const origin = normalizeOrigin(opts.domain);
  const startedAt = Date.now();
  const errors: string[] = [];
  let products = 0;
  let images = 0;
  let pages_fetched = 0;
  const maxListings = opts.maxListings ?? 5;
  const maxProducts = opts.maxProducts ?? 30;

  if (!opts.env.OPENROUTER_API_KEY) {
    yield {
      __type: "stats",
      source: "llm",
      products: 0,
      images: 0,
      pages_fetched: 0,
      errors: ["OPENROUTER_API_KEY not configured"],
      started_at: startedAt,
      finished_at: Date.now(),
    } satisfies StatsRow;
    return;
  }

  // 1. Homepage scrape.
  let homepageMd: string;
  try {
    const home = await firecrawlScrape(opts.env, {
      url: origin,
      formats: ["markdown"],
      onlyMainContent: false,
      tenant: opts.tenant,
      ctx: opts.ctx,
    });
    if (!home.data?.markdown) {
      errors.push("homepage scrape returned no markdown");
      yield finalStats(startedAt, products, images, pages_fetched, errors);
      return;
    }
    homepageMd = home.data.markdown;
    pages_fetched += 1;
  } catch (e) {
    errors.push(`homepage scrape: ${(e as Error).message}`);
    yield finalStats(startedAt, products, images, pages_fetched, errors);
    return;
  }

  // 2. LLM picks listing URLs.
  let listings: string[];
  try {
    listings = (await listingUrlsFromHomepage(opts.env, origin, homepageMd, opts.tenant)).slice(
      0,
      maxListings,
    );
  } catch (e) {
    errors.push(`listing-url extraction: ${(e as Error).message}`);
    yield finalStats(startedAt, products, images, pages_fetched, errors);
    return;
  }
  if (listings.length === 0) {
    errors.push("LLM found no listing URLs on the homepage");
    yield finalStats(startedAt, products, images, pages_fetched, errors);
    return;
  }

  // 3+4. Scrape each listing, extract product cards.
  for (const listing of listings) {
    if (products >= maxProducts) break;
    let listingMd: string;
    try {
      const got = await firecrawlScrape(opts.env, {
        url: listing,
        formats: ["markdown"],
        onlyMainContent: true,
        tenant: opts.tenant,
        ctx: opts.ctx,
      });
      if (!got.data?.markdown) {
        errors.push(`listing ${listing}: no markdown`);
        continue;
      }
      listingMd = got.data.markdown;
      pages_fetched += 1;
    } catch (e) {
      errors.push(`scrape ${listing}: ${(e as Error).message}`);
      continue;
    }

    let extracted: ExtractedProduct[];
    try {
      extracted = await productsFromListing(opts.env, listing, listingMd, opts.tenant);
    } catch (e) {
      errors.push(`extract ${listing}: ${(e as Error).message}`);
      continue;
    }

    for (const p of extracted) {
      if (products >= maxProducts) break;
      const now = Date.now();
      const productId = crypto.randomUUID();
      const productRow: ProductRow = {
        __type: "product",
        id: productId,
        brand_id: opts.brandId,
        external_id: null,
        url: p.url ?? listing,
        title: p.name,
        description: p.description ?? null,
        price_cents: toCents(p.price),
        currency: p.currency ?? null,
        available: 1,
        platform: "llm",
        raw_json: JSON.stringify({ source: "llm", listing, extracted: p }),
        first_seen_at: now,
        last_seen_at: now,
      };
      yield productRow;
      products += 1;

      if (typeof p.image_url === "string" && p.image_url) {
        const img: ProductImageRow = {
          __type: "product_image",
          id: crypto.randomUUID(),
          product_id: productId,
          url: p.image_url,
          alt: null,
          width: null,
          height: null,
          position: 0,
        };
        yield img;
        images += 1;
      }
    }
  }

  yield finalStats(startedAt, products, images, pages_fetched, errors);
}

function finalStats(
  startedAt: number,
  products: number,
  images: number,
  pages_fetched: number,
  errors: string[],
): StatsRow {
  return {
    __type: "stats",
    source: "llm",
    products,
    images,
    pages_fetched,
    errors,
    started_at: startedAt,
    finished_at: Date.now(),
  };
}
