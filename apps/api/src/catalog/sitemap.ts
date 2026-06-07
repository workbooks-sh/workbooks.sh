// Sitemap + JSON-LD catalog adapter.
//
// Strategy:
//   1. Discover sitemap URLs from /robots.txt; fall back to /sitemap.xml.
//   2. Recursively expand sitemap indexes into a flat URL list.
//   3. Filter URLs whose path contains /product, /products, /shop, /p, /item.
//   4. Fetch each filtered URL concurrently (bounded), extract a Product
//      from <script type="application/ld+json"> blocks (schema.org Product).
//   5. Yield product + product_image + stats rows in the same shape as
//      shopify.ts / context.ts.
//
// Covers most non-Shopify storefronts (WooCommerce, BigCommerce, Squarespace,
// Webflow, custom) — context.dev caps at 12 and Shopify only works for
// Shopify, so this is the "long tail" adapter for everyone else.

import type { Bindings } from "../env.js";
import { firecrawlScrape } from "../scrape/firecrawl.js";
import { browserHeaders } from "../scrape/headers.js";
import type { CatalogRow, ProductImageRow, ProductRow, StatsRow } from "./shopify.js";

const DEFAULT_HEADERS = browserHeaders({ accept: "*/*" });
const HTML_HEADERS = browserHeaders();
const PRODUCT_PATH_RE = /\/(?:products?|p|shop|items?|store)(?:\/|$|\?)/i;
/** Non-product storefront paths that match PRODUCT_PATH_RE but never carry
 * a real Product JSON-LD — gift cards, the collection root, etc. */
const PRODUCT_EXCLUDE_RE = /\/products\/(?:gift-?cards?|gift-card|e-?gift)/i;
const PRICE_RE = /\d+(?:[.,]\d{1,2})?/;
const SITEMAP_LOC_RE = /<loc>\s*([^<\s]+)\s*<\/loc>/gi;
const SITEMAPINDEX_RE = /<sitemapindex\b/i;

function toCents(value: unknown): number | null {
  if (value == null) return null;
  if (typeof value === "number") return Math.round(value * 100);
  const s = String(value).trim();
  const m = PRICE_RE.exec(s);
  if (!m) return null;
  const num = Number.parseFloat(m[0].replace(",", "."));
  return Number.isFinite(num) ? Math.round(num * 100) : null;
}

function availabilityToInt(value: unknown): number {
  if (!value) return 1;
  const s = String(value).toLowerCase();
  if (s.includes("outofstock") || s.includes("out of stock") || s.includes("discontinued")) {
    return 0;
  }
  return 1;
}

function normalizeOrigin(domain: string): string {
  const stripped = domain.replace(/^https?:\/\//, "").replace(/\/$/, "");
  return `https://${stripped}`;
}

async function fetchText(url: string, signal?: AbortSignal): Promise<string | null> {
  try {
    const res = await fetch(url, { headers: DEFAULT_HEADERS, signal });
    if (res.status !== 200) return null;
    return await res.text();
  } catch {
    return null;
  }
}

async function fetchHtml(url: string, signal?: AbortSignal): Promise<string | null> {
  try {
    const res = await fetch(url, { headers: HTML_HEADERS, signal, redirect: "follow" });
    if (res.status !== 200) return null;
    const ctype = (res.headers.get("content-type") ?? "").toLowerCase();
    if (!ctype.includes("html")) return null;
    return await res.text();
  } catch {
    return null;
  }
}

async function discoverSitemaps(origin: string): Promise<string[]> {
  const candidates: string[] = [];
  const robots = await fetchText(`${origin}/robots.txt`);
  if (robots) {
    for (const line of robots.split("\n")) {
      const m = /^\s*sitemap:\s*(\S+)/i.exec(line);
      if (m?.[1]) candidates.push(m[1]);
    }
  }
  if (candidates.length === 0) {
    for (const path of ["/sitemap.xml", "/sitemap_index.xml"]) {
      const head = await fetch(origin + path, { method: "HEAD", headers: DEFAULT_HEADERS }).catch(
        () => null,
      );
      if (head && head.status < 400) candidates.push(origin + path);
    }
  }
  return candidates;
}

function parseSitemapXml(body: string): { sub: string[]; pages: string[] } {
  const locs: string[] = [];
  let m: RegExpExecArray | null = SITEMAP_LOC_RE.exec(body);
  while (m !== null) {
    if (m[1]) locs.push(m[1]);
    m = SITEMAP_LOC_RE.exec(body);
  }
  SITEMAP_LOC_RE.lastIndex = 0;
  if (SITEMAPINDEX_RE.test(body)) return { sub: locs, pages: [] };
  return { sub: [], pages: locs };
}

async function expandSitemaps(seeds: string[], maxUrls: number): Promise<string[]> {
  const seen = new Set<string>();
  const queue = [...seeds];
  const urls: string[] = [];
  while (queue.length > 0 && urls.length < maxUrls) {
    const next = queue.shift();
    if (!next || seen.has(next)) continue;
    seen.add(next);
    const body = await fetchText(next);
    if (!body) continue;
    const { sub, pages } = parseSitemapXml(body);
    queue.push(...sub);
    for (const u of pages) {
      urls.push(u);
      if (urls.length >= maxUrls) break;
    }
  }
  return urls;
}

/** Variant query params that point to the SAME product (a colorway / size
 * /  swatch), so two URLs differing only by these are one product. */
const VARIANT_QUERY_KEYS = ["color", "colour", "variant", "size", "swatch", "material"];

/** Collapse a product URL to its canonical form: drop variant query params
 * (?color=…) and any trailing slash, so colorway permutations dedupe. */
function canonicalProductUrl(parsed: URL): string {
  const u = new URL(parsed.toString());
  for (const k of VARIANT_QUERY_KEYS) u.searchParams.delete(k);
  u.hash = "";
  let path = u.pathname.replace(/\/+$/, "");
  if (path === "") path = "/";
  const qs = u.searchParams.toString();
  return `${u.origin}${path}${qs ? `?${qs}` : ""}`;
}

function filterProductUrls(urls: string[], origin: string): string[] {
  let originHost: string;
  try {
    originHost = new URL(origin).host;
  } catch {
    return [];
  }
  const out: string[] = [];
  const seen = new Set<string>();
  for (const u of urls) {
    let parsed: URL;
    try {
      parsed = new URL(u);
    } catch {
      continue;
    }
    if (parsed.host && parsed.host !== originHost) continue;
    if (!PRODUCT_PATH_RE.test(parsed.pathname)) continue;
    // Skip gift cards / non-product storefront pages.
    if (PRODUCT_EXCLUDE_RE.test(parsed.pathname)) continue;
    // Dedupe ?color= (and sibling) variant permutations to one product.
    const canon = canonicalProductUrl(parsed);
    if (seen.has(canon)) continue;
    seen.add(canon);
    out.push(canon);
  }
  return out;
}

// --- JSON-LD extraction --------------------------------------------------

const JSONLD_BLOCK_RE =
  /<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;

function* iterJsonLdBlocks(html: string): Generator<unknown> {
  let m: RegExpExecArray | null = JSONLD_BLOCK_RE.exec(html);
  while (m !== null) {
    const raw = m[1]?.trim();
    if (raw) {
      try {
        yield JSON.parse(raw);
      } catch {
        // skip malformed blocks
      }
    }
    m = JSONLD_BLOCK_RE.exec(html);
  }
  JSONLD_BLOCK_RE.lastIndex = 0;
}

function* walkJsonLdProducts(node: unknown): Generator<Record<string, unknown>> {
  if (Array.isArray(node)) {
    for (const item of node) yield* walkJsonLdProducts(item);
    return;
  }
  if (!node || typeof node !== "object") return;
  const obj = node as Record<string, unknown>;
  const graph = obj["@graph"];
  if (Array.isArray(graph)) yield* walkJsonLdProducts(graph);
  const typ = obj["@type"];
  const types: string[] = Array.isArray(typ)
    ? typ.filter((t): t is string => typeof t === "string")
    : typeof typ === "string"
      ? [typ]
      : [];
  if (types.some((t) => t.toLowerCase() === "product")) yield obj;
}

interface ExtractedProduct {
  source: "jsonld";
  title: string;
  description: string | null;
  price_cents: number | null;
  currency: string | null;
  available: number;
  external_id: string | null;
  images: string[];
}

function extractOffersPrice(offers: unknown): {
  price_cents: number | null;
  currency: string | null;
  available: number;
} {
  const list: Record<string, unknown>[] = Array.isArray(offers)
    ? offers.filter((o): o is Record<string, unknown> => !!o && typeof o === "object")
    : offers && typeof offers === "object"
      ? [offers as Record<string, unknown>]
      : [];
  let priceCents: number | null = null;
  let currency: string | null = null;
  let available = 1;
  for (const o of list) {
    const cents = toCents(o.price ?? o.lowPrice);
    if (cents !== null && (priceCents === null || cents < priceCents)) priceCents = cents;
    if (currency === null && typeof o.priceCurrency === "string") currency = o.priceCurrency;
    if (available === 1) available = availabilityToInt(o.availability);
  }
  return { price_cents: priceCents, currency, available };
}

function extractProduct(html: string): ExtractedProduct | null {
  for (const block of iterJsonLdBlocks(html)) {
    for (const product of walkJsonLdProducts(block)) {
      const name = product.name;
      if (typeof name !== "string" || !name.trim()) continue;
      const offers = extractOffersPrice(product.offers);
      const images: string[] = [];
      const raw = product.image;
      if (typeof raw === "string") {
        images.push(raw);
      } else if (Array.isArray(raw)) {
        for (const i of raw) {
          if (typeof i === "string") images.push(i);
          else if (i && typeof i === "object" && typeof (i as { url?: string }).url === "string") {
            images.push((i as { url: string }).url);
          }
        }
      }
      return {
        source: "jsonld",
        title: name.trim(),
        description: typeof product.description === "string" ? product.description : null,
        ...offers,
        external_id:
          typeof product.sku === "string"
            ? product.sku
            : typeof product.productID === "string"
              ? product.productID
              : null,
        images,
      };
    }
  }
  return null;
}

// --- Crawl orchestration -------------------------------------------------

export interface SitemapCrawlOptions {
  domain: string;
  brandId: string;
  maxUrls?: number;
  concurrency?: number;
  /** When provided, pages whose RAW HTML has no `@type:Product` JSON-LD
   * are re-fetched via Firecrawl (JS-rendered) before being counted as a
   * miss. Lets client-rendered storefronts (React/Vue PDPs that inject
   * JSON-LD at runtime) still yield products. */
  env?: Bindings;
  tenant?: string;
  ctx?: ExecutionContext;
  /** Cap on how many no-JSON-LD pages get the (costly) rendered retry. */
  maxRenderedRetries?: number;
}

/** Fetch a page's rendered HTML via Firecrawl and re-run JSON-LD
 * extraction. Returns null if Firecrawl is unconfigured/fails or the
 * rendered HTML still has no Product. */
async function renderedExtract(
  opts: SitemapCrawlOptions,
  url: string,
): Promise<ExtractedProduct | null> {
  if (!opts.env || !opts.tenant) return null;
  try {
    const res = await firecrawlScrape(opts.env, {
      url,
      formats: ["rawHtml", "html"],
      onlyMainContent: false,
      tenant: opts.tenant,
      ctx: opts.ctx,
    });
    const html = res.data?.rawHtml ?? res.data?.html ?? null;
    if (!html) return null;
    return extractProduct(html);
  } catch {
    return null;
  }
}

async function bounded<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  async function worker(): Promise<void> {
    while (true) {
      const i = next++;
      if (i >= items.length) return;
      results[i] = await fn(items[i] as T);
    }
  }
  const workers = Array.from({ length: Math.min(limit, items.length) }, () => worker());
  await Promise.all(workers);
  return results;
}

export async function* crawlSitemap(opts: SitemapCrawlOptions): AsyncGenerator<CatalogRow> {
  const startedAt = Date.now();
  const maxUrls = Math.min(opts.maxUrls ?? 50, 200);
  const concurrency = opts.concurrency ?? 6;
  const errors: string[] = [];
  let products = 0;
  let images = 0;
  let urlsConsidered = 0;
  let urlsFetched = 0;
  let extractionFailures = 0;

  const origin = normalizeOrigin(opts.domain);
  const seeds = await discoverSitemaps(origin);
  if (seeds.length === 0) {
    errors.push("no sitemap discovered (robots.txt or /sitemap.xml)");
    yield {
      __type: "stats",
      source: "sitemap",
      products: 0,
      images: 0,
      pages_fetched: 0,
      errors,
      started_at: startedAt,
      finished_at: Date.now(),
    } satisfies StatsRow;
    return;
  }

  const allUrls = await expandSitemaps(seeds, maxUrls * 4);
  const productUrls = filterProductUrls(allUrls, origin).slice(0, maxUrls);
  urlsConsidered = productUrls.length;

  const extracted = await bounded(productUrls, concurrency, async (url) => {
    const html = await fetchHtml(url);
    if (html === null) return { url, product: null, fetched: false };
    return { url, product: extractProduct(html), fetched: true };
  });

  // Rendered fallback: pages we fetched but found no JSON-LD Product on
  // are likely client-rendered — retry a bounded number via Firecrawl.
  let renderedRecovered = 0;
  if (opts.env && opts.tenant) {
    const maxRendered = opts.maxRenderedRetries ?? 8;
    const misses = extracted.filter((e) => e.fetched && e.product === null).slice(0, maxRendered);
    const rendered = await bounded(misses, Math.min(concurrency, 4), async (miss) => ({
      url: miss.url,
      product: await renderedExtract(opts, miss.url),
    }));
    const byUrl = new Map(rendered.map((r) => [r.url, r.product]));
    for (const e of extracted) {
      if (e.fetched && e.product === null && byUrl.get(e.url)) {
        e.product = byUrl.get(e.url) ?? null;
        if (e.product) renderedRecovered += 1;
      }
    }
  }

  for (const item of extracted) {
    if (!item.fetched) continue;
    urlsFetched += 1;
    if (item.product === null) {
      extractionFailures += 1;
      continue;
    }
    const now = Date.now();
    const productId = crypto.randomUUID();
    const row: ProductRow = {
      __type: "product",
      id: productId,
      brand_id: opts.brandId,
      external_id: item.product.external_id,
      url: item.url,
      title: item.product.title,
      description: item.product.description,
      price_cents: item.product.price_cents,
      currency: item.product.currency,
      available: item.product.available,
      platform: "sitemap",
      raw_json: JSON.stringify({ source: "jsonld", images: item.product.images }),
      first_seen_at: now,
      last_seen_at: now,
    };
    yield row;
    products += 1;

    for (let i = 0; i < item.product.images.length; i++) {
      const img = item.product.images[i];
      if (!img) continue;
      const imgRow: ProductImageRow = {
        __type: "product_image",
        id: crypto.randomUUID(),
        product_id: productId,
        url: img,
        alt: null,
        width: null,
        height: null,
        position: i,
      };
      yield imgRow;
      images += 1;
    }
  }

  const stats: StatsRow = {
    __type: "stats",
    source: "sitemap",
    products,
    images,
    pages_fetched: urlsFetched,
    errors: [
      ...errors,
      ...(extractionFailures > 0 ? [`${extractionFailures} pages had no JSON-LD Product`] : []),
      ...(renderedRecovered > 0
        ? [`recovered ${renderedRecovered} products via rendered (Firecrawl) retry`]
        : []),
      ...(urlsConsidered === 0 ? ["no URLs matched product-path heuristic in sitemap"] : []),
      ...(products === 0 && urlsConsidered > 0
        ? [
            `sitemap: ${urlsConsidered} product-path URLs but 0 yielded JSON-LD Product — ` +
              `escalate to llm/Firecrawl`,
          ]
        : []),
    ],
    started_at: startedAt,
    finished_at: Date.now(),
  };
  yield stats;
}
