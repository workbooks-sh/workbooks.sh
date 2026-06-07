// Scrapecreators wrapper — covers Meta Ad Library, Google Ads
// Transparency advertiser search, and Instagram/TikTok/LinkedIn profile
// lookups. Real endpoints (verified live, paths matter):
//
//   GET /v1/facebook/adLibrary/search/ads?query&country
//   GET /v1/google/adLibrary/advertisers/search?query
//   GET /v1/instagram/profile?handle
//   GET /v1/tiktok/profile?handle
//   GET /v1/linkedin/ads/search?query
//
// All return { success, credits_remaining, … }. We don't track credits
// in vendor_calls today but they're worth surfacing in /usage later.
//
// Docs: https://docs.scrapecreators.com
// Auth: x-api-key header, key in env.SCRAPECREATORS_API_KEY.

import type { Bindings } from "../env.js";
import { vendorFetch } from "../vendor.js";

const BASE = "https://api.scrapecreators.com";

async function scGet<T>(
  env: Bindings,
  path: string,
  query: Record<string, string | undefined>,
  tenant: string,
  ctx?: ExecutionContext,
  cacheTtl = 1800,
): Promise<T | null> {
  if (!env.SCRAPECREATORS_API_KEY) return null;
  const url = new URL(BASE + path);
  for (const [k, v] of Object.entries(query)) {
    if (v !== undefined && v !== "") url.searchParams.set(k, v);
  }
  const res = await vendorFetch(env, {
    provider: "social-data",
    tenant,
    url: url.toString(),
    method: "GET",
    headers: { "x-api-key": env.SCRAPECREATORS_API_KEY },
    cacheTtl,
    rateLimit: 30,
    metadata: { path },
    ctx,
  });
  if (!res.ok) return null;
  try {
    return (await res.json()) as T;
  } catch {
    return null;
  }
}

// -- Meta Ad Library ------------------------------------------------------

export interface ScMetaAdSnapshot {
  page_id?: string;
  page_name?: string;
  page_profile_uri?: string;
  page_profile_picture_url?: string;
  branded_content?: unknown;
  [k: string]: unknown;
}

export interface ScMetaAd {
  ad_archive_id: string;
  page_id?: string;
  is_active?: boolean;
  snapshot?: ScMetaAdSnapshot;
  [k: string]: unknown;
}

export interface MetaAdLibrarySearchOptions {
  query: string;
  country?: string;
  cursor?: string;
  tenant: string;
  ctx?: ExecutionContext;
}

export interface MetaAdLibrarySearchResult {
  ads: ScMetaAd[];
  /** Pagination cursor for the next page, if more results exist. */
  cursor: string | null;
  /** Convenience flag: true when cursor is non-null. */
  has_more: boolean;
}

export async function metaAdLibrarySearch(
  env: Bindings,
  opts: MetaAdLibrarySearchOptions,
): Promise<MetaAdLibrarySearchResult> {
  const query: Record<string, string> = {
    query: opts.query,
    country: opts.country ?? "US",
  };
  if (opts.cursor) query.cursor = opts.cursor;
  const body = await scGet<{
    searchResults?: ScMetaAd[];
    cursor?: string;
    nextCursor?: string;
    next_cursor?: string;
    paging?: { next?: string; cursors?: { after?: string } };
  }>(env, "/v1/facebook/adLibrary/search/ads", query, opts.tenant, opts.ctx);
  const ads = body?.searchResults ?? [];
  // Scrapecreators returns the cursor under one of several names depending on
  // endpoint generation; coalesce so callers don't have to know which.
  const cursor =
    body?.cursor ??
    body?.nextCursor ??
    body?.next_cursor ??
    body?.paging?.cursors?.after ??
    body?.paging?.next ??
    null;
  return {
    ads,
    cursor: cursor ?? null,
    has_more: !!cursor,
  };
}

// -- Google Ads Transparency advertiser search ----------------------------

export interface ScGoogleAdvertiser {
  name: string;
  advertiser_id: string;
  region?: string;
  number_of_ads_estimate?: number;
}

export interface ScGoogleAdvertiserSearchResult {
  advertisers: ScGoogleAdvertiser[];
  websites: Array<{ domain: string }>;
}

export async function googleAdvertiserSearch(
  env: Bindings,
  query: string,
  tenant: string,
  ctx?: ExecutionContext,
): Promise<ScGoogleAdvertiserSearchResult> {
  const body = await scGet<{
    advertisers?: ScGoogleAdvertiser[];
    websites?: Array<{ domain: string }>;
  }>(env, "/v1/google/adLibrary/advertisers/search", { query }, tenant, ctx, 86_400);
  return {
    advertisers: body?.advertisers ?? [],
    websites: body?.websites ?? [],
  };
}

// -- Profile lookups (Instagram, TikTok) ----------------------------------

export interface ScInstagramProfile {
  data?: { user?: Record<string, unknown> };
}

export function instagramProfile(
  env: Bindings,
  handle: string,
  tenant: string,
  ctx?: ExecutionContext,
): Promise<ScInstagramProfile | null> {
  return scGet<ScInstagramProfile>(env, "/v1/instagram/profile", { handle }, tenant, ctx, 86_400);
}

export interface ScTiktokProfile {
  data?: Record<string, unknown>;
}

export function tiktokProfile(
  env: Bindings,
  handle: string,
  tenant: string,
  ctx?: ExecutionContext,
): Promise<ScTiktokProfile | null> {
  return scGet<ScTiktokProfile>(env, "/v1/tiktok/profile", { handle }, tenant, ctx, 86_400);
}

// -- LinkedIn Ads ---------------------------------------------------------

export interface ScLinkedinAd {
  /** LinkedIn ad/creative id. Field name varies by endpoint generation. */
  id?: string;
  ad_id?: string;
  creative_id?: string;
  advertiser?: string;
  advertiser_name?: string;
  url?: string;
  ad_url?: string;
  headline?: string;
  body?: string;
  text?: string;
  cta?: string;
  call_to_action?: string;
  [k: string]: unknown;
}

export interface LinkedinAdsSearchOptions {
  query: string;
  tenant: string;
  ctx?: ExecutionContext;
}

export interface LinkedinAdsSearchResult {
  ads: ScLinkedinAd[];
}

export async function linkedinAdsSearch(
  env: Bindings,
  opts: LinkedinAdsSearchOptions,
): Promise<LinkedinAdsSearchResult> {
  const body = await scGet<{
    ads?: ScLinkedinAd[];
    searchResults?: ScLinkedinAd[];
    results?: ScLinkedinAd[];
  }>(env, "/v1/linkedin/ads/search", { query: opts.query }, opts.tenant, opts.ctx);
  const ads = body?.ads ?? body?.searchResults ?? body?.results ?? [];
  return { ads };
}
