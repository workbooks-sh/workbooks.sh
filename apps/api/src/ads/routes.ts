// Ads endpoints. Only /ads/search is implemented today; OAuth-backed
// /ads/sync per provider lands in ad-3ul.15/16/17.
//
// /ads/search is a ScrapeCreators-only ad-library fan-out: it dispatches
// to the Meta (Facebook), Google Ads Transparency, and LinkedIn ad
// libraries by `source`, normalises every hit into the Ad shape from
// @brandnana/schema, and tags each row with provenance in the `source`
// field. Web research / brand discovery lives elsewhere (Valyu); this
// surface returns ADS, not web pages.

import { Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";
import { scrapeGoogleAds } from "../scrape/google_ads.js";
import {
  MetaAdLibraryNotApprovedError,
  listAdAccounts,
  listMyAds,
  searchAdLibrary,
} from "../scrape/meta.js";
import { linkedinAdsSearch, metaAdLibrarySearch } from "../scrape/scrapecreators.js";

const ads = new Hono<{ Bindings: Bindings }>();
ads.use("*", requireBearer);

type SearchSource = "meta" | "google" | "linkedin" | "all";

interface NormalisedAd {
  source: "meta" | "google" | "linkedin" | "manual";
  external_id: string;
  url: string | null;
  body: string | null;
  cta: string | null;
  first_seen_at: number;
  last_seen_at: number;
  raw_json: Record<string, unknown>;
}

ads.post("/search", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    query?: string;
    source?: SearchSource;
    limit?: number;
    brand?: string;
  };
  if (!body.query) {
    return c.json({ error: "missing_query" }, 400);
  }
  const user = c.get("user");
  const limit = Math.min(Math.max(body.limit ?? 50, 1), 100);
  const source: SearchSource = body.source ?? "all";
  // ScrapeCreators ad-library searches key off the brand name; fall back
  // to the free-text query when no explicit brand was supplied.
  const brand = body.brand ?? body.query;

  const now = Date.now();
  const results: NormalisedAd[] = [];
  const warnings: string[] = [];

  // ScrapeCreators-only fan-out. Each leg is caught individually so one
  // unavailable library (missing key / pending approval) never sinks the
  // others, and a real failure is surfaced in `warnings` instead of being
  // silently swallowed into an empty array.

  // -- Meta (Facebook) Ad Library ----------------------------------------
  if (source === "meta" || source === "all") {
    try {
      const { ads: rows } = await metaAdLibrarySearch(c.env, {
        query: brand,
        country: "US",
        tenant: user.id,
        ctx: c.executionCtx,
      });
      if (rows.length === 0) {
        warnings.push(
          c.env.SCRAPECREATORS_API_KEY
            ? `meta: no ad-library matches for "${brand}"`
            : "meta: leg unavailable (SCRAPECREATORS_API_KEY not configured)",
        );
      }
      for (const ad of rows) {
        results.push({
          source: "meta",
          external_id: ad.ad_archive_id,
          url: ad.snapshot?.page_profile_uri ?? null,
          body: ad.snapshot?.page_name ?? null,
          cta: null,
          first_seen_at: now,
          last_seen_at: now,
          raw_json: { provider: "meta-public", ad },
        });
      }
    } catch (e) {
      warnings.push(`meta: ${(e as Error).message}`);
    }
  }

  // -- Google Ads Transparency Center ------------------------------------
  if (source === "google" || source === "all") {
    try {
      const g = await scrapeGoogleAds(c.env, {
        brand,
        tenant: user.id,
        ctx: c.executionCtx,
      });
      if (g.source === "no_match" || g.advertiser_id === null) {
        warnings.push(g.warning ?? `google: no advertiser match for "${brand}"`);
      } else if (g.creative_ids.length === 0) {
        warnings.push(`google: advertiser ${g.advertiser_id} found but no creatives extracted`);
      }
      for (const creativeId of g.creative_ids) {
        results.push({
          source: "google",
          external_id: creativeId,
          url: g.advertiser_url,
          body: g.brand,
          cta: null,
          first_seen_at: now,
          last_seen_at: now,
          raw_json: {
            provider: "google-transparency",
            advertiser_id: g.advertiser_id,
            advertiser_url: g.advertiser_url,
            creative_id: creativeId,
          },
        });
      }
    } catch (e) {
      warnings.push(`google: ${(e as Error).message}`);
    }
  }

  // -- LinkedIn Ad Library -----------------------------------------------
  if (source === "linkedin" || source === "all") {
    try {
      const { ads: rows } = await linkedinAdsSearch(c.env, {
        query: brand,
        tenant: user.id,
        ctx: c.executionCtx,
      });
      if (rows.length === 0) {
        warnings.push(
          c.env.SCRAPECREATORS_API_KEY
            ? `linkedin: no ad-library matches for "${brand}"`
            : "linkedin: leg unavailable (SCRAPECREATORS_API_KEY not configured)",
        );
      }
      let i = 0;
      for (const ad of rows) {
        const externalId = ad.id ?? ad.ad_id ?? ad.creative_id ?? `linkedin-${brand}-${i}`;
        i += 1;
        results.push({
          source: "linkedin",
          external_id: externalId,
          url: ad.url ?? ad.ad_url ?? null,
          body: ad.headline ?? ad.body ?? ad.text ?? ad.advertiser_name ?? ad.advertiser ?? null,
          cta: ad.cta ?? ad.call_to_action ?? null,
          first_seen_at: now,
          last_seen_at: now,
          raw_json: { provider: "linkedin", ad },
        });
      }
    } catch (e) {
      warnings.push(`linkedin: ${(e as Error).message}`);
    }
  }

  // De-duplicate by external_id within the same source.
  const seen = new Set<string>();
  const deduped = results.filter((a) => {
    const k = `${a.source}:${a.external_id}`;
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });

  return c.json({
    query: body.query,
    source,
    count: deduped.length,
    ads: deduped.slice(0, limit),
    warnings,
  });
});

// POST /ads/google { brand: "..." }
// Scrapes the Google Ads Transparency Center for an advertiser. Returns
// the discovered advertiser_id, advertiser_url, and any creative ids
// we could extract from the rendered page.
ads.post("/google", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    brand?: string;
    advertiser_url?: string;
  };
  if (!body.brand && !body.advertiser_url) {
    return c.json({ error: "missing_brand_or_advertiser_url" }, 400);
  }
  const user = c.get("user");
  try {
    const result = await scrapeGoogleAds(c.env, {
      brand: body.brand,
      advertiserUrl: body.advertiser_url,
      tenant: user.id,
      ctx: c.executionCtx,
    });
    return c.json(result);
  } catch (e) {
    return c.json({ error: "scrape_failed", message: (e as Error).message }, 502);
  }
});

// GET /ads/meta/accounts — list ad accounts visible to META_GRAPH_TOKEN.
// In prod this'll read the user's stored Meta token from D1; for now
// it's the worker's dev token.
ads.get("/meta/accounts", async (c) => {
  const user = c.get("user");
  try {
    const accounts = await listAdAccounts(c.env, {
      tenant: user.id,
      ctx: c.executionCtx,
    });
    return c.json({ accounts });
  } catch (e) {
    return c.json({ error: "meta_error", message: (e as Error).message }, 502);
  }
});

// POST /ads/meta { ad_account_id, limit? } — fetch ads from one ad account.
// Stream-friendly output: { source: 'meta', count, ads: [...] }.
ads.post("/meta", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    ad_account_id?: string;
    limit?: number;
  };
  if (!body.ad_account_id) {
    return c.json({ error: "missing_ad_account_id" }, 400);
  }
  const user = c.get("user");
  try {
    const rows = await listMyAds(c.env, {
      adAccountId: body.ad_account_id,
      limit: body.limit,
      tenant: user.id,
      ctx: c.executionCtx,
    });
    const now = Date.now();
    const ads = rows.map((r) => ({
      source: "meta" as const,
      external_id: r.id,
      url: r.link_url,
      body: r.creative_body ?? r.name,
      cta: r.cta_type,
      first_seen_at: now,
      last_seen_at: now,
      raw_json: { provider: "meta", ad: r },
    }));
    return c.json({ source: "meta", count: ads.length, ads });
  } catch (e) {
    return c.json({ error: "meta_error", message: (e as Error).message }, 502);
  }
});

// POST /ads/meta/library { query, countries?, limit? } — Ad Library search.
// Returns 503 with actionable guidance until Meta Ad Library API is approved.
ads.post("/meta/library", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    query?: string;
    countries?: string[];
    limit?: number;
  };
  if (!body.query) return c.json({ error: "missing_query" }, 400);
  const user = c.get("user");
  try {
    const data = await searchAdLibrary(c.env, {
      query: body.query,
      countries: body.countries,
      limit: body.limit,
      tenant: user.id,
      ctx: c.executionCtx,
    });
    return c.json({ source: "meta-ads-library", count: data.length, ads: data });
  } catch (e) {
    if (e instanceof MetaAdLibraryNotApprovedError) {
      return c.json({ error: "ad_library_not_approved", message: e.message }, 503);
    }
    return c.json({ error: "meta_error", message: (e as Error).message }, 502);
  }
});

export default ads;
