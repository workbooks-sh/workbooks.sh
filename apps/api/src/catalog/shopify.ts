// Shopify catalog walker — TypeScript port of packages/catalog-crawler's
// Python adapter, running directly inside the Worker so /catalog/crawl
// doesn't need an external sandbox for the Shopify fast-path.
//
// Walks /products.json?page=N&limit=250 until an empty page; fetches
// /meta.json once for currency. Yields product + product_image rows
// in the same shape the Python adapter does (so the CLI's row handler
// works unchanged).

import { browserHeaders } from "../scrape/headers.js";

const PAGE_SIZE = 250;
const FETCH_TIMEOUT_MS = 8000;
/** Number of products at/below which a Shopify crawl is considered
 * suspiciously thin (matches the context.dev 12-cap) and emits a LOUD
 * stats warning so the agent escalates instead of silently shipping a
 * truncated catalog. */
const THIN_CATALOG_THRESHOLD = 12;

export type CatalogRow = ProductRow | ProductImageRow | StatsRow;

export interface ProductRow {
  __type: "product";
  id: string;
  brand_id: string;
  external_id: string | null;
  url: string;
  title: string;
  description: string | null;
  price_cents: number | null;
  currency: string | null;
  available: number;
  platform: string;
  raw_json: string;
  first_seen_at: number;
  last_seen_at: number;
}

export interface ProductImageRow {
  __type: "product_image";
  id: string;
  product_id: string;
  url: string;
  alt: string | null;
  width: number | null;
  height: number | null;
  position: number;
}

export interface StatsRow {
  __type: "stats";
  source: string;
  products: number;
  images: number;
  pages_fetched: number;
  errors: string[];
  started_at: number;
  finished_at: number;
}

function normalizeOrigin(domain: string): string {
  const raw = domain.trim();
  const withScheme = raw.includes("://") ? raw : `https://${raw}`;
  return withScheme.replace(/\/+$/, "");
}

/** Bare host (no scheme, no path) for a domain. */
function hostOf(domain: string): string {
  try {
    return new URL(normalizeOrigin(domain)).host.toLowerCase();
  } catch {
    return domain
      .trim()
      .replace(/^https?:\/\//, "")
      .replace(/\/.*$/, "")
      .toLowerCase();
  }
}

/**
 * Build the ordered list of host variants to try for a domain:
 * apex ↔ www. A *.myshopify.com backend (if known) goes last because it
 * is the most reliable but least canonical. De-duped, order-preserving.
 */
export function hostVariants(domain: string, myshopify?: string | null): string[] {
  const host = hostOf(domain);
  const out: string[] = [];
  const push = (h: string) => {
    const clean = h.toLowerCase().replace(/\/+$/, "");
    if (clean && !out.includes(clean)) out.push(clean);
  };
  push(host);
  if (host.startsWith("www.")) {
    push(host.slice(4));
  } else {
    push(`www.${host}`);
  }
  if (myshopify) push(myshopify.replace(/^https?:\/\//, "").replace(/\/.*$/, ""));
  return out;
}

/** Grep a homepage's HTML for a *.myshopify.com backend host. Shopify
 * storefronts reference their canonical *.myshopify.com origin in
 * shop config / asset URLs even when the public domain is custom. */
export function grepMyshopifyHost(html: string | null | undefined): string | null {
  if (!html) return null;
  const m = /([a-z0-9-]+\.myshopify\.com)/i.exec(html);
  return m?.[1] ? m[1].toLowerCase() : null;
}

async function fetchHomepageHtml(origin: string): Promise<string | null> {
  try {
    const r = await fetchWithTimeout(origin, FETCH_TIMEOUT_MS, "text/html");
    if (!r.ok) return null;
    return await r.text();
  } catch {
    return null;
  }
}

function stripHtml(html: string | null | undefined): string | null {
  if (!html) return null;
  const text = html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return text || null;
}

function toCents(price: unknown): number | null {
  if (price == null || price === "") return null;
  const n = typeof price === "number" ? price : Number.parseFloat(String(price));
  return Number.isFinite(n) ? Math.round(n * 100) : null;
}

async function fetchWithTimeout(
  url: string,
  ms = FETCH_TIMEOUT_MS,
  accept = "application/json",
): Promise<Response> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), ms);
  try {
    return await fetch(url, {
      signal: ctrl.signal,
      headers: browserHeaders({ accept }),
      redirect: "follow",
    });
  } finally {
    clearTimeout(t);
  }
}

async function fetchCurrency(origin: string): Promise<string | null> {
  try {
    const r = await fetchWithTimeout(`${origin}/meta.json`);
    if (!r.ok) return null;
    const j = (await r.json()) as { currency?: unknown };
    return typeof j.currency === "string" ? j.currency : null;
  } catch {
    return null;
  }
}

interface RawShopifyProduct {
  id?: number | string;
  title?: string;
  handle?: string;
  body_html?: string;
  variants?: Array<{ price?: string | number; available?: boolean }>;
  images?: Array<{
    src?: string;
    alt?: string | null;
    width?: number | null;
    height?: number | null;
    position?: number | null;
  }>;
}

/** Sentinel: /products.json returned 404 (or non-JSON HTML) — this host
 * is NOT serving the Shopify products API, even if it is a Shopify store
 * behind a headless/custom front. Caller should try the next host variant
 * rather than treat it as "catalog exhausted". */
class ProductsJsonUnavailable extends Error {
  constructor(public readonly status: number) {
    super(`/products.json unavailable: HTTP ${status}`);
    this.name = "ProductsJsonUnavailable";
  }
}

async function fetchPage(origin: string, page: number): Promise<RawShopifyProduct[]> {
  const r = await fetchWithTimeout(`${origin}/products.json?page=${page}&limit=${PAGE_SIZE}`);
  if (r.status === 404) throw new ProductsJsonUnavailable(404);
  if (!r.ok) throw new Error(`page ${page}: HTTP ${r.status}`);
  const ctype = r.headers.get("content-type") ?? "";
  // Custom/headless fronts answer /products.json with a 200 HTML page
  // (the storefront app). That is NOT the products API — escalate.
  if (!ctype.includes("json")) throw new ProductsJsonUnavailable(r.status);
  const j = (await r.json()) as { products?: RawShopifyProduct[] };
  return Array.isArray(j.products) ? j.products : [];
}

export interface ShopifyCrawlOptions {
  domain: string;
  brandId: string;
  maxPages?: number;
  /** Pre-resolved host variant known to serve products.json (from
   * detectShopify). When set, it is tried first. */
  shopifyHost?: string | null;
  /** A *.myshopify.com backend grepped from the homepage, appended to the
   * host-variant cascade as the most-reliable fallback. */
  myshopify?: string | null;
}

/** Tri-state Shopify detection result.
 *   - "yes"     : a host variant serves the products.json API → use shopify.
 *   - "no"      : we have positive evidence this is NOT Shopify (a host
 *                 answered cleanly with non-Shopify content / a non-404
 *                 error). Caller should pick another strategy.
 *   - "unknown" : every probe was inconclusive (timeouts, 404s on every
 *                 host, network errors). Do NOT assume "no" — a headless
 *                 Shopify front 404s /products.json on the public host but
 *                 may be reachable on the apex or a *.myshopify.com backend,
 *                 so the caller should still try the host-variant cascade. */
export type ShopifyDetect = "yes" | "no" | "unknown";

export interface IsShopifyResult {
  state: ShopifyDetect;
  /** The host variant that served products.json, if state === "yes". */
  shopifyHost: string | null;
  /** A *.myshopify.com backend grepped from the homepage, if found. */
  myshopify: string | null;
  /** Per-host probe notes, for loud diagnostics. */
  notes: string[];
}

async function probeProductsJson(
  host: string,
): Promise<{ hit: boolean; unavailable: boolean; note: string }> {
  const origin = normalizeOrigin(host);
  try {
    const r = await fetchWithTimeout(`${origin}/products.json?limit=1`, 4000);
    if (r.status === 404) return { hit: false, unavailable: true, note: `${host}: 404` };
    if (!r.ok) return { hit: false, unavailable: false, note: `${host}: HTTP ${r.status}` };
    const ctype = r.headers.get("content-type") ?? "";
    if (!ctype.includes("json")) {
      // 200 but HTML → headless front, products API not exposed here.
      return { hit: false, unavailable: true, note: `${host}: 200 non-JSON (${ctype || "?"})` };
    }
    const j = (await r.json()) as { products?: unknown };
    if (Array.isArray(j.products)) return { hit: true, unavailable: false, note: `${host}: ok` };
    return { hit: false, unavailable: false, note: `${host}: JSON without products[]` };
  } catch (e) {
    return { hit: false, unavailable: true, note: `${host}: ${(e as Error).message}` };
  }
}

/**
 * Tri-state Shopify detection that is NOT blind to host. Probes
 * /products.json across apex ↔ www, and if those are inconclusive, greps
 * the homepage for a *.myshopify.com backend and probes that too.
 *
 * The old boolean swallowed a 404 (or a 200-HTML headless front) to
 * `false`, demoting full Shopify catalogs to the 12-cap context.dev path.
 * This returns "unknown" in that case so the cascade can still try
 * sitemap / llm instead of giving up.
 */
export async function isShopify(domain: string): Promise<ShopifyDetect> {
  return (await detectShopify(domain)).state;
}

export async function detectShopify(domain: string): Promise<IsShopifyResult> {
  const notes: string[] = [];
  let sawDefinitiveNo = false;
  let sawUnavailable = false;

  // 1. apex ↔ www.
  for (const host of hostVariants(domain)) {
    const p = await probeProductsJson(host);
    notes.push(p.note);
    if (p.hit) return { state: "yes", shopifyHost: host, myshopify: null, notes };
    if (p.unavailable) sawUnavailable = true;
    else sawDefinitiveNo = true;
  }

  // 2. Inconclusive so far — grep the homepage for a *.myshopify.com
  //    backend and probe that. This recovers headless Shopify stores
  //    whose public domain 404s /products.json.
  const homeHtml = await fetchHomepageHtml(normalizeOrigin(domain));
  const myshopify = grepMyshopifyHost(homeHtml);
  if (myshopify) {
    const p = await probeProductsJson(myshopify);
    notes.push(p.note);
    if (p.hit) return { state: "yes", shopifyHost: myshopify, myshopify, notes };
    if (p.unavailable) sawUnavailable = true;
    else sawDefinitiveNo = true;
  }

  // A *.myshopify.com reference at all is strong evidence it IS Shopify,
  // even if the API host is gated — keep it "unknown" so the cascade
  // (sitemap/llm) runs rather than asserting "no".
  if (myshopify || sawUnavailable) {
    return { state: "unknown", shopifyHost: null, myshopify, notes };
  }
  if (sawDefinitiveNo) return { state: "no", shopifyHost: null, myshopify: null, notes };
  return { state: "unknown", shopifyHost: null, myshopify: null, notes };
}

/** Walk one host's /products.json. Returns the page-0 status so the
 * caller can decide whether to try the next host variant. */
async function* walkHostProducts(
  origin: string,
  opts: { brandId: string; maxPages: number; currency: string | null },
): AsyncGenerator<
  | { kind: "row"; row: ProductRow | ProductImageRow }
  | { kind: "unavailable" }
  | { kind: "error"; message: string }
  | { kind: "done"; products: number; pages: number }
> {
  let products = 0;
  let pages = 0;
  for (let page = 1; page <= opts.maxPages; page++) {
    let batch: RawShopifyProduct[];
    try {
      batch = await fetchPage(origin, page);
    } catch (e) {
      if (e instanceof ProductsJsonUnavailable) {
        // Only treat as "host has no products API" on the FIRST page;
        // mid-walk 404 means the catalog simply ended.
        if (page === 1) {
          yield { kind: "unavailable" };
          return;
        }
        break;
      }
      yield { kind: "error", message: (e as Error).message };
      break;
    }
    pages += 1;
    if (batch.length === 0) break;

    for (const raw of batch) {
      const handle = raw.handle ?? "";
      const variants = raw.variants ?? [];
      let priceCents: number | null = null;
      let available = false;
      for (const v of variants) {
        const c = toCents(v.price);
        if (c != null && (priceCents == null || c < priceCents)) priceCents = c;
        if (v.available) available = true;
      }
      const now = Date.now();
      const productId = crypto.randomUUID();
      const productUrl = handle ? `${origin}/products/${handle}` : origin;

      yield {
        kind: "row",
        row: {
          __type: "product",
          id: productId,
          brand_id: opts.brandId,
          external_id: raw.id != null ? String(raw.id) : null,
          url: productUrl,
          title: raw.title ?? "",
          description: stripHtml(raw.body_html),
          price_cents: priceCents,
          currency: opts.currency,
          available: available ? 1 : 0,
          platform: "shopify",
          raw_json: JSON.stringify(raw),
          first_seen_at: now,
          last_seen_at: now,
        },
      };
      products += 1;

      const imgs = raw.images ?? [];
      for (let i = 0; i < imgs.length; i++) {
        const img = imgs[i];
        if (!img || typeof img.src !== "string" || !img.src) continue;
        yield {
          kind: "row",
          row: {
            __type: "product_image",
            id: crypto.randomUUID(),
            product_id: productId,
            url: img.src,
            alt: img.alt ?? null,
            width: img.width ?? null,
            height: img.height ?? null,
            position: img.position ?? i,
          },
        };
      }
    }
    if (batch.length < PAGE_SIZE) break;
  }
  yield { kind: "done", products, pages };
}

/** Async generator that yields CatalogRows as it walks the Shopify catalog.
 *
 * Host-variant aware: tries shopifyHost (if known) → apex ↔ www →
 * grepped *.myshopify.com, moving to the next variant whenever a host
 * has no products.json API (the classic headless-front 404). Emits a
 * LOUD stats error when the winning host yields ≤ THIN_CATALOG_THRESHOLD
 * products so the agent escalates instead of shipping a truncated catalog.
 */
export async function* crawlShopify(opts: ShopifyCrawlOptions): AsyncGenerator<CatalogRow> {
  const startedAt = Date.now();
  const errors: string[] = [];
  let products = 0;
  let images = 0;
  let pages_fetched = 0;

  const maxPages = opts.maxPages ?? 200;

  // Ordered, de-duped host cascade.
  const hosts: string[] = [];
  const pushHost = (h?: string | null) => {
    if (!h) return;
    const clean = h.toLowerCase().replace(/^https?:\/\//, "").replace(/\/.*$/, "");
    if (clean && !hosts.includes(clean)) hosts.push(clean);
  };
  pushHost(opts.shopifyHost);
  for (const h of hostVariants(opts.domain, opts.myshopify)) pushHost(h);

  let winningHost: string | null = null;
  const triedNotes: string[] = [];

  for (const host of hosts) {
    const origin = normalizeOrigin(host);
    const currency = await fetchCurrency(origin);
    let hostProducts = 0;
    let unavailable = false;
    for await (const ev of walkHostProducts(origin, { brandId: opts.brandId, maxPages, currency })) {
      if (ev.kind === "row") {
        yield ev.row;
        if (ev.row.__type === "product") {
          products += 1;
          hostProducts += 1;
        } else {
          images += 1;
        }
      } else if (ev.kind === "unavailable") {
        unavailable = true;
        triedNotes.push(`${host}: no products.json (headless/custom front)`);
      } else if (ev.kind === "error") {
        errors.push(`${host}: ${ev.message}`);
      } else if (ev.kind === "done") {
        pages_fetched += ev.pages;
      }
    }
    if (!unavailable && hostProducts > 0) {
      winningHost = host;
      break;
    }
    // else: try next host variant.
  }

  if (winningHost === null && products === 0) {
    errors.push(
      `shopify: no host variant served /products.json (tried ${hosts.join(", ")}). ` +
        triedNotes.join("; "),
    );
  }

  // LOUD thin-catalog warning: a Shopify store with ≤12 products is almost
  // always a truncated/wrong-host read, not a real micro-catalog. Surface
  // it so the auto-cascade escalates to sitemap/llm rather than shipping it.
  if (products > 0 && products <= THIN_CATALOG_THRESHOLD) {
    errors.push(
      `shopify: only ${products} products from ${winningHost ?? "?"} ` +
        `(≤${THIN_CATALOG_THRESHOLD}) — suspiciously thin; likely a truncated or ` +
        `wrong-host read. Escalate to sitemap/llm or retry host variants.`,
    );
  }

  yield {
    __type: "stats",
    source: "shopify",
    products,
    images,
    pages_fetched,
    errors,
    started_at: startedAt,
    finished_at: Date.now(),
  };
}
