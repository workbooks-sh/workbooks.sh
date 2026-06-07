// context.dev wrapper (rebrand of logo.dev).
//
// Covers: brand retrieve, styleguide, fonts, web scrape, product
// extract. Replaces both logo.dev (fast logo) and Brandfetch (full
// brand record) in our stack — context.dev's `/v1/brand/retrieve`
// returns logos + colors + descriptors + slogan + backdrops in a
// single call.
//
// Docs: https://docs.context.dev
// Auth: Authorization: Bearer <key>, env.CONTEXT_DEV_API_KEY.
//
// Endpoint inventory (all under https://api.context.dev/v1):
//
//   Brand Intelligence:
//     GET  /brand/retrieve?domain=          — logos, colors, fonts, metadata
//
//   Web Extraction:
//     GET  /web/styleguide?domain=          — design system tokens
//     GET  /web/fonts?domain=               — font families + usage stats
//     POST /web/product/extract-single      — structured product from URL
//
//   Web Scraping:
//     GET  /scrape/html?url=                — raw HTML, auto proxy escalation
//     GET  /scrape/markdown?url=            — clean markdown from page
//     GET  /scrape/screenshot?url=          — viewport screenshot URL
//     GET  /scrape/sitemap?domain=          — sitemap URLs
//
// NOTE: The existing endpoints `/brand/styleguide` and `/brand/fonts`
// below use the legacy path schema from logo.dev (pre-rebrand). Context.dev
// may still accept them under backwards-compat routing.  The canonical new
// paths are /web/styleguide and /web/fonts.  Both are represented here.
// The /scrape/html endpoint is the WAF-bypass scrape tier used by fetchBrand().

import type { Bindings } from "../env.js";
import { vendorFetch } from "../vendor.js";

const BASE = "https://api.context.dev/v1";

export interface ContextBrandColor {
  hex: string;
  name?: string;
}

export interface ContextBrandLogo {
  url: string;
  mode?: "light" | "dark";
  type?: "icon" | "logo" | "wordmark" | string;
  colors?: ContextBrandColor[];
  resolution?: { width?: number; height?: number; aspect_ratio?: number };
}

export interface ContextBrandResponse {
  status: string;
  brand?: {
    domain?: string;
    title?: string;
    description?: string;
    slogan?: string;
    colors?: ContextBrandColor[];
    logos?: ContextBrandLogo[];
    backdrops?: Array<{ url: string; colors?: ContextBrandColor[] }>;
    fonts?: Array<{ name?: string; family?: string }>;
    links?: Record<string, string>;
    industry?: { naics?: string; sic?: string; name?: string };
    socials?: Record<string, string>;
  };
}

export interface ContextExtractProduct {
  status: string;
  product?: {
    name?: string;
    description?: string;
    price?: { amount?: number; currency?: string };
    images?: string[];
    features?: string[];
    sku?: string;
    url?: string;
  };
}

// context.dev returns transient 429s under load (every brief in eval saw at
// least one section degrade). Retry those + 503s with brief backoff before
// surfacing the error. vendorFetch only caches 2xx so retries hit the wire.
const RETRY_DELAYS_MS = [600, 1500];

async function contextGet<T>(
  env: Bindings,
  path: string,
  query: Record<string, string>,
  tenant: string,
  ctx?: ExecutionContext,
): Promise<T> {
  if (!env.CONTEXT_DEV_API_KEY) {
    throw new Error("CONTEXT_DEV_API_KEY is not configured on the worker");
  }
  const url = new URL(BASE + path);
  for (const [k, v] of Object.entries(query)) {
    url.searchParams.set(k, v);
  }
  let res: Response | undefined;
  for (let attempt = 0; attempt <= RETRY_DELAYS_MS.length; attempt++) {
    res = await vendorFetch(env, {
      provider: "context-dev",
      tenant,
      url: url.toString(),
      method: "GET",
      headers: { authorization: `Bearer ${env.CONTEXT_DEV_API_KEY}` },
      cacheTtl: 86_400, // 24h — brand records change slowly
      rateLimit: 60,
      metadata: { path, ...query },
      ctx,
    });
    if (res.ok || (res.status !== 429 && res.status !== 503)) break;
    const delay = RETRY_DELAYS_MS[attempt];
    if (delay === undefined) break;
    await new Promise<void>((r) => setTimeout(r, delay));
  }
  if (!res || !res.ok) {
    const status = res?.status ?? 0;
    const body = res ? await res.text() : "no response";
    throw new Error(`context.dev ${path} ${status}: ${body}`);
  }
  return (await res.json()) as T;
}

export function retrieveBrand(
  env: Bindings,
  domain: string,
  tenant: string,
  ctx?: ExecutionContext,
): Promise<ContextBrandResponse> {
  return contextGet<ContextBrandResponse>(env, "/brand/retrieve", { domain }, tenant, ctx);
}

export function extractProduct(
  env: Bindings,
  url: string,
  tenant: string,
  ctx?: ExecutionContext,
): Promise<ContextExtractProduct> {
  return contextGet<ContextExtractProduct>(env, "/extract/product", { url }, tenant, ctx);
}

export interface ContextStyleguide {
  status: string;
  domain: string;
  styleguide: {
    mode?: "light" | "dark";
    typography?: Record<string, unknown>;
    components?: Record<string, unknown>;
    [k: string]: unknown;
  };
}

export interface ContextFonts {
  status: string;
  domain: string;
  fonts: Array<{
    font: string;
    fallbacks?: string[];
    uses?: string[];
    num_elements?: number;
    num_words?: number;
    percent_elements?: number;
    percent_words?: number;
  }>;
  fontLinks?: Record<string, unknown>;
}

export interface ContextScreenshot {
  status: string;
  domain: string;
  screenshot: string;
  screenshotType?: string;
  width?: number;
  height?: number;
  code?: number;
}

export function getStyleguide(
  env: Bindings,
  domain: string,
  tenant: string,
  ctx?: ExecutionContext,
): Promise<ContextStyleguide> {
  return contextGet<ContextStyleguide>(env, "/brand/styleguide", { domain }, tenant, ctx);
}

export function getFonts(
  env: Bindings,
  domain: string,
  tenant: string,
  ctx?: ExecutionContext,
): Promise<ContextFonts> {
  return contextGet<ContextFonts>(env, "/brand/fonts", { domain }, tenant, ctx);
}

export function getScreenshot(
  env: Bindings,
  domain: string,
  tenant: string,
  ctx?: ExecutionContext,
): Promise<ContextScreenshot> {
  return contextGet<ContextScreenshot>(env, "/brand/screenshot", { domain }, tenant, ctx);
}
