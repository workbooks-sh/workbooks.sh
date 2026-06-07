// Meta Graph API wrapper.
//
// Three flavours of Meta data are relevant to brandnana:
//
//   1. User's own ads — /act_<id>/ads. Requires ads_read /
//      ads_management scope. We pull these into the user's local
//      SQLite as their authoritative ad-creative record.
//
//   2. Public Ad Library — /ads_archive. Anyone can query in theory,
//      but in practice Meta requires a separate Ad Library API
//      approval step (facebook.com/ads/library/api) — identity
//      verification + terms acceptance. Until that's done the API
//      returns OAuthException code=10 sub=2332002.
//
//   3. Page-level insights — /<page_id>/posts, /<page_id>/insights.
//      Not used today; opportunity for future brand-presence sync.
//
// Auth: a USER access token (Bearer or `access_token=` query param).
// In dev we accept META_GRAPH_TOKEN as a global fallback so the worker
// owner can dogfood without per-user OAuth. Production needs the OAuth
// flow in apps/api/src/oauth/meta.ts to mint per-user tokens.

import type { Bindings } from "../env.js";
import { vendorFetch } from "../vendor.js";

const GRAPH = "https://graph.facebook.com/v22.0";

/**
 * Resolve the access token to use for a call. Order:
 *   1. explicit per-call token (e.g. from CLI flag)
 *   2. user's stored OAuth token (provider_connections row)
 *   3. global META_GRAPH_TOKEN (dev fallback)
 * Returns null if none available; callers should 401/503 in that case.
 */
export async function resolveMetaToken(
  env: Bindings,
  userId: string,
  explicit?: string,
): Promise<string | null> {
  if (explicit) return explicit;
  const stored = await env.DB.prepare(
    "SELECT access_token FROM provider_connections WHERE user_id = ? AND provider = 'meta'",
  )
    .bind(userId)
    .first<{ access_token: string }>();
  if (stored?.access_token) return stored.access_token;
  return env.META_GRAPH_TOKEN ?? null;
}

export interface MetaAdRow {
  id: string;
  ad_account_id: string;
  status: string | null;
  effective_status: string | null;
  name: string | null;
  created_time: string | null;
  updated_time: string | null;
  creative_id: string | null;
  creative_body: string | null;
  creative_title: string | null;
  creative_image_url: string | null;
  creative_video_id: string | null;
  cta_type: string | null;
  link_url: string | null;
  raw: Record<string, unknown>;
}

interface RawAd {
  id: string;
  status?: string;
  effective_status?: string;
  name?: string;
  created_time?: string;
  updated_time?: string;
  creative?: {
    id?: string;
    body?: string;
    title?: string;
    image_url?: string;
    video_id?: string;
    object_story_spec?: {
      link_data?: {
        message?: string;
        name?: string;
        link?: string;
        call_to_action?: { type?: string };
        image_hash?: string;
      };
    };
    asset_feed_spec?: unknown;
  };
}

function pickCreativeBody(c: RawAd["creative"] | undefined): string | null {
  if (!c) return null;
  if (c.body) return c.body;
  return c.object_story_spec?.link_data?.message ?? null;
}

function pickCreativeTitle(c: RawAd["creative"] | undefined): string | null {
  if (!c) return null;
  if (c.title) return c.title;
  return c.object_story_spec?.link_data?.name ?? null;
}

function pickLink(c: RawAd["creative"] | undefined): string | null {
  return c?.object_story_spec?.link_data?.link ?? null;
}

function pickCta(c: RawAd["creative"] | undefined): string | null {
  return c?.object_story_spec?.link_data?.call_to_action?.type ?? null;
}

function normaliseAd(raw: RawAd, adAccountId: string): MetaAdRow {
  return {
    id: raw.id,
    ad_account_id: adAccountId,
    status: raw.status ?? null,
    effective_status: raw.effective_status ?? null,
    name: raw.name ?? null,
    created_time: raw.created_time ?? null,
    updated_time: raw.updated_time ?? null,
    creative_id: raw.creative?.id ?? null,
    creative_body: pickCreativeBody(raw.creative),
    creative_title: pickCreativeTitle(raw.creative),
    creative_image_url: raw.creative?.image_url ?? null,
    creative_video_id: raw.creative?.video_id ?? null,
    cta_type: pickCta(raw.creative),
    link_url: pickLink(raw.creative),
    raw: raw as unknown as Record<string, unknown>,
  };
}

const AD_FIELDS = [
  "id",
  "name",
  "status",
  "effective_status",
  "created_time",
  "updated_time",
  "creative{id,body,title,image_url,video_id,object_story_spec}",
].join(",");

export interface ListMyAdsOptions {
  adAccountId: string;
  /** Override the global META_GRAPH_TOKEN with a per-user token. */
  accessToken?: string;
  limit?: number;
  tenant: string;
  ctx?: ExecutionContext;
}

export async function listMyAds(env: Bindings, opts: ListMyAdsOptions): Promise<MetaAdRow[]> {
  const token = await resolveMetaToken(env, opts.tenant, opts.accessToken);
  if (!token) {
    throw new Error(
      "Meta: no access token. Run `brandnana auth meta` to connect, or set META_GRAPH_TOKEN as a dev fallback.",
    );
  }
  const acctId = opts.adAccountId.startsWith("act_") ? opts.adAccountId : `act_${opts.adAccountId}`;

  const url = new URL(`${GRAPH}/${acctId}/ads`);
  url.searchParams.set("fields", AD_FIELDS);
  url.searchParams.set("limit", String(opts.limit ?? 50));
  url.searchParams.set("access_token", token);

  const res = await vendorFetch(env, {
    provider: "meta-ads",
    tenant: opts.tenant,
    url: url.toString(),
    method: "GET",
    cacheTtl: 600,
    rateLimit: 30,
    metadata: { ad_account_id: acctId },
    ctx: opts.ctx,
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Meta /ads ${res.status}: ${body}`);
  }
  const data = (await res.json()) as { data?: RawAd[]; error?: { message?: string } };
  if (data.error) {
    throw new Error(`Meta error: ${data.error.message ?? JSON.stringify(data.error)}`);
  }
  return (data.data ?? []).map((r) => normaliseAd(r, acctId));
}

export interface ListAdAccountsOptions {
  accessToken?: string;
  tenant: string;
  ctx?: ExecutionContext;
}

export interface MetaAdAccount {
  id: string;
  account_id: string;
  name?: string;
  account_status?: number;
}

export async function listAdAccounts(
  env: Bindings,
  opts: ListAdAccountsOptions,
): Promise<MetaAdAccount[]> {
  const token = await resolveMetaToken(env, opts.tenant, opts.accessToken);
  if (!token) {
    throw new Error("Meta: no access token. Run `brandnana auth meta` to connect.");
  }
  const url = new URL(`${GRAPH}/me/adaccounts`);
  url.searchParams.set("fields", "id,account_id,name,account_status");
  url.searchParams.set("access_token", token);

  const res = await vendorFetch(env, {
    provider: "meta-adaccounts",
    tenant: opts.tenant,
    url: url.toString(),
    method: "GET",
    cacheTtl: 600,
    rateLimit: 10,
    ctx: opts.ctx,
  });
  if (!res.ok) {
    throw new Error(`Meta /me/adaccounts ${res.status}: ${await res.text()}`);
  }
  const data = (await res.json()) as { data?: MetaAdAccount[] };
  return data.data ?? [];
}

export interface SearchAdLibraryOptions {
  query: string;
  countries?: string[];
  activeStatus?: "ACTIVE" | "INACTIVE" | "ALL";
  limit?: number;
  accessToken?: string;
  tenant: string;
  ctx?: ExecutionContext;
}

export class MetaAdLibraryNotApprovedError extends Error {
  constructor() {
    super(
      "Meta Ad Library API access not approved for this app. " +
        "Complete identity verification at https://www.facebook.com/ads/library/api " +
        "and accept the terms before this endpoint will work.",
    );
    this.name = "MetaAdLibraryNotApprovedError";
  }
}

export async function searchAdLibrary(env: Bindings, opts: SearchAdLibraryOptions) {
  const token = await resolveMetaToken(env, opts.tenant, opts.accessToken);
  if (!token) throw new Error("Meta: no access token. Run `brandnana auth meta` to connect.");
  const url = new URL(`${GRAPH}/ads_archive`);
  url.searchParams.set("search_terms", opts.query);
  url.searchParams.set("ad_reached_countries", JSON.stringify(opts.countries ?? ["US"]));
  url.searchParams.set("ad_active_status", opts.activeStatus ?? "ACTIVE");
  url.searchParams.set("limit", String(opts.limit ?? 25));
  url.searchParams.set(
    "fields",
    "id,ad_creation_time,ad_creative_bodies,ad_creative_link_titles,ad_snapshot_url,page_name,page_id",
  );
  url.searchParams.set("access_token", token);

  const res = await vendorFetch(env, {
    provider: "meta-ads-library",
    tenant: opts.tenant,
    url: url.toString(),
    method: "GET",
    cacheTtl: 3600,
    rateLimit: 30,
    metadata: { query: opts.query },
    ctx: opts.ctx,
  });
  const body = (await res.json()) as {
    data?: unknown[];
    error?: { code?: number; error_subcode?: number; message?: string };
  };
  if (body.error?.code === 10 && body.error.error_subcode === 2332002) {
    throw new MetaAdLibraryNotApprovedError();
  }
  if (!res.ok) {
    throw new Error(`Meta /ads_archive ${res.status}: ${JSON.stringify(body.error)}`);
  }
  return body.data ?? [];
}
