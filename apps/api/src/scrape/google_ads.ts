// Google Ads Transparency Center scrape pipeline.
//
// No official API exists for the Ads Transparency Center, so the flow is:
//   1. Use ScrapeCreators' advertiser search to find the advertiser's
//      transparency page (we don't hard-code search URLs since Google
//      rotates query params).
//   2. Use Firecrawl to render and extract markdown from the page.
//   3. Regex-extract advertiser_id + creative_ids; return both the
//      structured fields and the raw markdown so callers can do
//      richer extraction client-side.
//
// ToS-aware: each call goes through the vendor.ts cache (24h TTL) and
// per-tenant rate limiter (cap 10/min per tenant for this endpoint).
// We strongly recommend callers throttle their own usage; this is
// intended for ad research, not bulk surveillance.

import type { Bindings } from "../env.js";
import { firecrawlScrape } from "./firecrawl.js";
import { googleAdvertiserSearch } from "./scrapecreators.js";

const ADVERTISER_RE = /adstransparency\.google\.com\/advertiser\/(AR\d+|[A-Z0-9]+)/;
const CREATIVE_RE = /\/creative\/(CR\d+|[A-Z0-9]+)/g;

export interface GoogleAdsScrapeOptions {
  /** Brand name. Triggers a ScrapeCreators lookup for the advertiser page. */
  brand?: string;
  /** Direct advertiser URL (skip discovery). Reliable path. */
  advertiserUrl?: string;
  tenant: string;
  ctx?: ExecutionContext;
}

export interface GoogleAdsScrapeResult {
  brand: string | null;
  advertiser_id: string | null;
  advertiser_url: string | null;
  creative_ids: string[];
  markdown_excerpt: string | null;
  source: "direct" | "social-data+firecrawl" | "no_match";
  warning?: string;
}

async function discoverAdvertiserUrl(
  env: Bindings,
  brand: string,
  tenant: string,
  ctx?: ExecutionContext,
): Promise<string | null> {
  // ScrapeCreators' /v1/google/adLibrary/advertisers/search returns
  // advertiser IDs + ad counts directly. We pick the advertiser with the
  // most ads (proxy for "this is the brand's main account"). There is no
  // web-search fallback: if ScrapeCreators can't find the advertiser we
  // return null and the caller surfaces a truthful no_match + warning.
  if (env.SCRAPECREATORS_API_KEY) {
    const result = await googleAdvertiserSearch(env, brand, tenant, ctx);
    if (result.advertisers.length > 0) {
      const best = [...result.advertisers].sort(
        (a, b) => (b.number_of_ads_estimate ?? 0) - (a.number_of_ads_estimate ?? 0),
      )[0];
      if (best) {
        return `https://adstransparency.google.com/advertiser/${best.advertiser_id}?region=${best.region ?? "US"}`;
      }
    }
  }

  return null;
}

export async function scrapeGoogleAds(
  env: Bindings,
  opts: GoogleAdsScrapeOptions,
): Promise<GoogleAdsScrapeResult> {
  let advertiserUrl = opts.advertiserUrl ?? null;
  let source: GoogleAdsScrapeResult["source"] = "direct";

  if (!advertiserUrl) {
    if (!opts.brand) {
      throw new Error("scrapeGoogleAds: requires either advertiserUrl or brand");
    }
    advertiserUrl = await discoverAdvertiserUrl(env, opts.brand, opts.tenant, opts.ctx);
    source = advertiserUrl ? "social-data+firecrawl" : "no_match";
  }

  if (!advertiserUrl) {
    return {
      brand: opts.brand ?? null,
      advertiser_id: null,
      advertiser_url: null,
      creative_ids: [],
      markdown_excerpt: null,
      source,
      warning:
        "Could not auto-discover the advertiser page from ScrapeCreators. Pass `advertiser_url` directly — copy it from the URL bar at adstransparency.google.com after searching for the brand.",
    };
  }

  const advertiserMatch = ADVERTISER_RE.exec(advertiserUrl);
  const advertiserId = advertiserMatch?.[1] ?? null;

  const scrape = await firecrawlScrape(env, {
    url: advertiserUrl,
    formats: ["markdown"],
    onlyMainContent: true,
    tenant: opts.tenant,
    ctx: opts.ctx,
  });

  const markdown = scrape.data?.markdown ?? null;
  const creativeIds = new Set<string>();
  if (markdown) {
    let m: RegExpExecArray | null = CREATIVE_RE.exec(markdown);
    while (m !== null) {
      if (m[1]) creativeIds.add(m[1]);
      m = CREATIVE_RE.exec(markdown);
    }
  }

  return {
    brand: opts.brand ?? null,
    advertiser_id: advertiserId,
    advertiser_url: advertiserUrl,
    creative_ids: [...creativeIds],
    markdown_excerpt: markdown ? markdown.slice(0, 4000) : null,
    source,
  };
}
