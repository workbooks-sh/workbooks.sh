// POST /catalog/crawl — streams catalog rows as NDJSON.
//
// Dispatch:
//   strategy=auto       → REAL cascade: shopify → sitemap(JSON-LD) → llm,
//                         with host-variant retry (apex↔www↔*.myshopify.com)
//                         and escalation when a rung is thin (≤12 products)
//   strategy=shopify    → /products.json walker (best for Shopify)
//   strategy=context-dev → context.dev /products (12-product cap)
//   strategy=sitemap    → robots.txt + /sitemap.xml + JSON-LD (long tail)
//   strategy=llm        → Firecrawl + OpenRouter (last resort, costs tokens)
//
// The SDK client.catalog.crawl() consumes this stream and writes rows
// into the user's local SQLite.

import { Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";
import { crawlContext } from "./context.js";
import {
  claimCrawl,
  finishCrawl,
  heartbeatCrawl,
  readCrawlStatus,
  reclaimCrawl,
} from "./coordinator.js";
import { crawlLlm } from "./llm.js";
import { type CatalogRow, crawlShopify, detectShopify } from "./shopify.js";
import { crawlSitemap } from "./sitemap.js";

/** Below this product count an adapter's result is considered too thin to
 * trust as a full catalog, so `auto` escalates to the next rung. Mirrors
 * the context.dev 12-cap / shopify thin-warning threshold. */
const AUTO_THIN_THRESHOLD = 12;

const catalog = new Hono<{ Bindings: Bindings }>();
catalog.use("*", requireBearer);

type Strategy = "auto" | "shopify" | "context-dev" | "sitemap" | "llm";

interface CrawlBody {
  domain?: string;
  strategy?: Strategy;
  brand_id?: string;
  max_urls?: number;
  /** If true and another crawl for (tenant, domain) is in-flight, run
   * anyway instead of refusing. Default false — dedup is the safer
   * behavior for agents that retry on transient errors. */
  force?: boolean;
}

type Adapter = "shopify" | "context-dev" | "sitemap" | "llm";

interface RunOpts {
  env: Bindings;
  domain: string;
  brandId: string;
  tenant: string;
  maxUrls?: number;
  ctx?: ExecutionContext;
  /** Pre-resolved Shopify host (from detectShopify) so shopify doesn't
   * re-probe. */
  shopifyHost?: string | null;
  myshopify?: string | null;
}

/** Run a single concrete adapter as a CatalogRow stream. */
export function runStrategy(adapter: Adapter, o: RunOpts): AsyncIterable<CatalogRow> {
  if (adapter === "shopify") {
    return crawlShopify({
      domain: o.domain,
      brandId: o.brandId,
      maxPages: o.maxUrls ? Math.ceil(o.maxUrls / 250) : undefined,
      shopifyHost: o.shopifyHost,
      myshopify: o.myshopify,
    });
  }
  if (adapter === "llm") {
    return crawlLlm({
      env: o.env,
      domain: o.domain,
      brandId: o.brandId,
      tenant: o.tenant,
      maxProducts: o.maxUrls,
      ctx: o.ctx,
    });
  }
  if (adapter === "sitemap") {
    return crawlSitemap({
      domain: o.domain,
      brandId: o.brandId,
      maxUrls: o.maxUrls,
      env: o.env,
      tenant: o.tenant,
      ctx: o.ctx,
    });
  }
  return crawlContext({
    env: o.env,
    domain: o.domain,
    brandId: o.brandId,
    tenant: o.tenant,
    maxProducts: o.maxUrls,
    ctx: o.ctx,
  });
}

/**
 * REAL auto-cascade: shopify → sitemap(JSON-LD) → llm(Firecrawl).
 *
 * Each rung streams its rows live. After a rung's terminal stats row we
 * inspect the product count; if it is > AUTO_THIN_THRESHOLD we stop and
 * seal a merged stats. Otherwise we DISCARD that rung's (thin) rows and
 * fall through to the next, accumulating every rung's errors so the final
 * stats is a LOUD audit trail of what was tried.
 *
 * Rows from a thin rung are buffered (not emitted) so the consumer's
 * SQLite isn't polluted with a half-catalog that the next rung supersedes;
 * only the WINNING rung's rows reach the stream. If the cascade is
 * exhausted without any rung clearing the threshold, the BEST rung seen
 * (most products) is flushed as best-effort — never a silent empty. The
 * terminal stats row records `source` = the winning adapter and `errors` =
 * the full chain.
 */
async function* autoCascade(o: RunOpts): AsyncGenerator<CatalogRow> {
  const detect = await detectShopify(o.domain);
  // Order the cascade. Shopify first unless we have positive "no" evidence.
  const rungs: Adapter[] =
    detect.state === "no" ? ["sitemap", "llm"] : ["shopify", "sitemap", "llm"];

  const chainErrors: string[] = [];
  let started_at = Date.now();

  interface RungResult {
    adapter: Adapter;
    buffer: CatalogRow[];
    products: number;
    images: number;
    pages: number;
  }
  let best: RungResult | null = null;

  for (let i = 0; i < rungs.length; i++) {
    const adapter = rungs[i] as Adapter;
    const isLast = i === rungs.length - 1;
    const buffer: CatalogRow[] = [];
    let rungProducts = 0;
    let rungImages = 0;
    let rungPages = 0;
    let rungErrors: string[] = [];
    let rungStartedAt = Date.now();

    for await (const row of runStrategy(adapter, {
      ...o,
      shopifyHost: adapter === "shopify" ? detect.shopifyHost : undefined,
      myshopify: detect.myshopify,
    })) {
      if (row.__type === "stats") {
        rungProducts = row.products;
        rungImages = row.images;
        rungPages = row.pages_fetched;
        rungErrors = row.errors ?? [];
        rungStartedAt = row.started_at || rungStartedAt;
      } else {
        buffer.push(row);
      }
    }
    if (i === 0) started_at = rungStartedAt;
    for (const e of rungErrors) chainErrors.push(`[${adapter}] ${e}`);

    const here: RungResult = {
      adapter,
      buffer,
      products: rungProducts,
      images: rungImages,
      pages: rungPages,
    };
    if (!best || here.products > best.products) best = here;

    const enough = rungProducts > AUTO_THIN_THRESHOLD;
    if (enough) {
      for (const row of buffer) yield row;
      yield {
        __type: "stats",
        source: `auto:${adapter}`,
        products: rungProducts,
        images: rungImages,
        pages_fetched: rungPages,
        errors: chainErrors,
        started_at,
        finished_at: Date.now(),
      };
      return;
    }
    if (isLast) {
      // Exhausted with no rung clearing the threshold — flush the BEST
      // (most-products) rung as best-effort, loudly.
      const win = best;
      if (win.products > 0) {
        chainErrors.push(
          `auto: exhausted cascade (${rungs.join(" → ")}); best rung "${win.adapter}" yielded ` +
            `${win.products} products (≤${AUTO_THIN_THRESHOLD}). Flushed as best-effort.`,
        );
        for (const row of win.buffer) yield row;
      } else {
        chainErrors.push(
          `auto: exhausted cascade (${rungs.join(" → ")}); EVERY rung returned 0 products ` +
            `for ${o.domain}. Recorded as a loud-empty data point.`,
        );
      }
      yield {
        __type: "stats",
        source: `auto:${win.adapter}`,
        products: win.products,
        images: win.images,
        pages_fetched: win.pages,
        errors: chainErrors,
        started_at,
        finished_at: Date.now(),
      };
      return;
    }
    // Thin rung — discard buffer, note it, fall through.
    chainErrors.push(
      `[${adapter}] thin result (${rungProducts} products ≤${AUTO_THIN_THRESHOLD}) — escalating`,
    );
  }
}

// --- harvestCatalog: single callable for the Brand Scout harvester ------
//
// Contract (cross-agent): runs the REAL auto-cascade + host-variant retry,
// caps products, mirrors product images to R2, and FAILS LOUD (warnings
// carry the full chain; productCount===0 with warnings is the loud-empty,
// never a silent empty).

const PUBLIC_ASSET_BASE = "https://api.brandnana.net";
const MAX_MIRROR_IMAGES = 60;
const MIRROR_FETCH_TIMEOUT_MS = 10_000;
const MAX_MIRROR_BYTES = 8 * 1024 * 1024;

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function extFromContentType(ct: string | null, url: string): string {
  const sub = (ct ?? "").split("/")[1]?.split(";")[0]?.trim();
  if (sub === "jpeg") return "jpg";
  if (sub && /^[a-z0-9]+$/.test(sub)) return sub;
  const m = /\.([a-zA-Z0-9]{2,5})(?:\?|$)/.exec(url);
  return (m?.[1] ?? "bin").toLowerCase();
}

/** sha256-dedup a single image URL into the ASSETS bucket; returns the
 * public /assets/<sha>.<ext> URL or null. Self-contained mirror so
 * harvestCatalog compiles independently of the MEDIA agent's helper. */
async function mirrorImage(env: Bindings, url: string): Promise<string | null> {
  if (!env.ASSETS || typeof url !== "string" || !/^https?:\/\//.test(url)) return null;
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), MIRROR_FETCH_TIMEOUT_MS);
  try {
    const r = await fetch(url, { signal: ctrl.signal, redirect: "follow" });
    if (!r.ok) return null;
    const buf = await r.arrayBuffer();
    if (buf.byteLength === 0 || buf.byteLength > MAX_MIRROR_BYTES) return null;
    const bytes = new Uint8Array(buf);
    const hash = await sha256Hex(bytes);
    const ct = r.headers.get("content-type");
    const filename = `${hash}.${extFromContentType(ct, url)}`;
    const key = `images/${filename}`;
    const existing = await env.ASSETS.head(key);
    if (!existing) {
      await env.ASSETS.put(key, bytes, {
        httpMetadata: { contentType: ct ?? "application/octet-stream" },
        customMetadata: { source_url: url.slice(0, 1024) },
      });
    }
    return `${PUBLIC_ASSET_BASE}/assets/${filename}`;
  } catch {
    return null;
  } finally {
    clearTimeout(t);
  }
}

export interface HarvestCatalogResult {
  products: Array<Record<string, unknown>>;
  productCount: number;
  strategy: string;
  mirrored: number;
  warnings: string[];
}

/**
 * Harvest a brand's full product catalog in one call. Runs the real
 * auto-cascade (shopify → sitemap(JSON-LD) → llm) with host-variant retry
 * (apex ↔ www ↔ *.myshopify.com), caps the product count, mirrors product
 * images to R2, and FAILS LOUD: every rung's diagnostics land in
 * `warnings`, and a zero-product result is a recorded data point (warnings
 * explain why), never a silent empty.
 */
export async function harvestCatalog(
  env: Bindings,
  args: { domain: string; tenant: string; maxUrls?: number; ctx?: ExecutionContext },
): Promise<HarvestCatalogResult> {
  const cap = Math.max(1, Math.min(args.maxUrls ?? 250, 1000));
  const brandId = crypto.randomUUID();
  const warnings: string[] = [];

  // products keyed by row.id → product object (so we can attach images).
  const products = new Map<string, Record<string, unknown>>();
  // product_id → image URLs (raw, pre-mirror).
  const imagesByProduct = new Map<string, string[]>();
  let strategy = "auto:none";

  try {
    for await (const row of autoCascade({
      env,
      domain: args.domain,
      brandId,
      tenant: args.tenant,
      maxUrls: cap,
      ctx: args.ctx,
    })) {
      if (row.__type === "product") {
        if (products.size >= cap) continue;
        products.set(row.id, { ...row, images: [] as string[] });
      } else if (row.__type === "product_image") {
        const list = imagesByProduct.get(row.product_id) ?? [];
        list.push(row.url);
        imagesByProduct.set(row.product_id, list);
      } else if (row.__type === "stats") {
        strategy = row.source;
        for (const e of row.errors ?? []) warnings.push(e);
      }
    }
  } catch (e) {
    warnings.push(`harvestCatalog: cascade threw — ${(e as Error).message}`);
  }

  // Mirror images to R2 (bounded + sha-deduped), rewrite product.images.
  const allImageUrls: string[] = [];
  for (const [pid, urls] of imagesByProduct) {
    if (products.has(pid)) allImageUrls.push(...urls);
  }
  const toMirror = [...new Set(allImageUrls)].slice(0, MAX_MIRROR_IMAGES);
  const mirrorMap = new Map<string, string>();
  if (env.ASSETS) {
    const results = await Promise.all(
      toMirror.map(async (u) => ({ u, mirrored: await mirrorImage(env, u) })),
    );
    for (const { u, mirrored } of results) if (mirrored) mirrorMap.set(u, mirrored);
  }
  if (allImageUrls.length > MAX_MIRROR_IMAGES) {
    warnings.push(
      `catalog: ${allImageUrls.length} product images found; mirrored first ${MAX_MIRROR_IMAGES} to R2`,
    );
  }

  // Attach (mirrored-where-possible) images back onto each product.
  for (const [pid, prod] of products) {
    const raw = imagesByProduct.get(pid) ?? [];
    prod.images = raw.map((u) => mirrorMap.get(u) ?? u);
  }

  const productList = [...products.values()];
  if (productList.length === 0) {
    warnings.push(
      `catalog: 0 products harvested for ${args.domain} via ${strategy} — recorded as a ` +
        `loud-empty data point (see chain above), not a silent miss`,
    );
  }

  return {
    products: productList,
    productCount: productList.length,
    strategy,
    mirrored: mirrorMap.size,
    warnings,
  };
}

catalog.post("/crawl", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as CrawlBody;
  if (!body.domain) {
    return c.json({ error: "missing_domain" }, 400);
  }
  const user = c.get("user");
  const brandId = body.brand_id ?? crypto.randomUUID();
  const strategy = body.strategy ?? "auto";

  // Choose the stream. `auto` now runs the REAL cascade
  // (shopify → sitemap → llm) inside autoCascade(); explicit strategies
  // run a single adapter. `chosen` is the coordinator/header label.
  const runOpts: RunOpts = {
    env: c.env,
    domain: body.domain,
    brandId,
    tenant: user.id,
    maxUrls: body.max_urls,
    ctx: c.executionCtx,
  };

  let chosen: "auto" | Adapter;
  let rows: AsyncIterable<CatalogRow>;
  if (strategy === "auto") {
    chosen = "auto";
    rows = autoCascade(runOpts);
  } else {
    chosen = strategy; // "shopify" | "context-dev" | "sitemap" | "llm"
    rows = runStrategy(strategy, runOpts);
  }

  // Claim a coordinator slot for (tenant, domain). Refuses if a crawl
  // is already in-flight unless --force was passed. Heartbeats roll
  // counts forward; finishCrawl seals the slot at the end.
  const crawlId = crypto.randomUUID();
  let coordinated = false;
  if (c.env.CRAWL && !body.force) {
    const claim = await claimCrawl(c.env.CRAWL, user.id, body.domain, crawlId, chosen);
    if (!claim.ok) {
      return c.json(
        {
          error: "crawl_in_progress",
          message:
            "Another crawl for this brand is already running. Pass force=true to override, or GET /catalog/status/<domain> for progress.",
          state: claim.state,
        },
        409,
      );
    }
    coordinated = true;
  } else if (c.env.CRAWL && body.force) {
    // Forced strategy-retry — SUPERSEDE any stale running slot so /status
    // (and heartbeats) track THIS attempt, not a prior crawl whose
    // crawl_id no longer matches. reclaimCrawl always installs the new
    // slot; claimCrawl would 409 and leave the stale crawl_id active,
    // silently dropping this crawl's heartbeats.
    await reclaimCrawl(c.env.CRAWL, user.id, body.domain, crawlId, chosen).catch(() => {});
    coordinated = true;
  }

  const env = c.env;
  const tenantId = user.id;
  const domain = body.domain;
  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      let products = 0;
      let images = 0;
      let pagesFetched = 0;
      const collectedErrors: string[] = [];
      let lastBeatAt = 0;
      try {
        for await (const row of rows) {
          controller.enqueue(encoder.encode(`${JSON.stringify(row)}\n`));
          if (row.__type === "product") products++;
          else if (row.__type === "product_image") images++;
          else if (row.__type === "stats") {
            pagesFetched = row.pages_fetched ?? pagesFetched;
            if (Array.isArray(row.errors)) collectedErrors.push(...row.errors);
          }
          // Beat at most every 1s to keep DO load down. Always beat on
          // stats (terminal row) so /status reflects final counts.
          const now = Date.now();
          if (coordinated && env.CRAWL && (row.__type === "stats" || now - lastBeatAt > 1000)) {
            lastBeatAt = now;
            env.CRAWL &&
              (await heartbeatCrawl(env.CRAWL, tenantId, domain, crawlId, {
                products,
                images,
                pages_fetched: pagesFetched,
              }));
          }
        }
        if (coordinated && env.CRAWL) {
          await finishCrawl(env.CRAWL, tenantId, domain, crawlId, "complete", collectedErrors);
        }
      } catch (e) {
        const msg = (e as Error).message;
        const err = {
          __type: "stats" as const,
          source: chosen,
          products,
          images,
          pages_fetched: pagesFetched,
          errors: [...collectedErrors, msg],
          started_at: 0,
          finished_at: Date.now(),
        };
        controller.enqueue(encoder.encode(`${JSON.stringify(err)}\n`));
        if (coordinated && env.CRAWL) {
          await finishCrawl(env.CRAWL, tenantId, domain, crawlId, "failed", [
            ...collectedErrors,
            msg,
          ]);
        }
      } finally {
        controller.close();
      }
    },
  });

  return new Response(stream, {
    status: 200,
    headers: {
      "content-type": "application/x-ndjson",
      "x-brandnana-strategy": chosen,
      "x-brandnana-brand-id": brandId,
      "x-brandnana-crawl-id": crawlId,
    },
  });
});

// GET /catalog/status/:domain — current crawl state from the DO. Returns
// {status: "idle"} if no crawl has ever run for this (tenant, domain).
catalog.get("/status/:domain", async (c) => {
  if (!c.env.CRAWL) return c.json({ error: "coordinator_not_configured" }, 503);
  const domain = c.req.param("domain");
  if (!domain) return c.json({ error: "missing_domain" }, 400);
  const user = c.get("user");
  const state = await readCrawlStatus(c.env.CRAWL, user.id, domain);
  return c.json({ domain, state });
});

export default catalog;
