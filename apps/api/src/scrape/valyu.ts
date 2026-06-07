// Valyu Search wrapper. Used for general WEB RESEARCH — resolving a brand's
// canonical domain, competitor/brand discovery, and book-research legs.
//
// Ad intelligence does NOT go through here; that's ScrapeCreators
// (metaAdLibrarySearch / scrapeGoogleAds / googleAdvertiserSearch /
// linkedinAdsSearch). Valyu is web search only.
//
// Docs: https://docs.valyu.ai
// Auth: x-api-key header, key in env.VALYU_API_KEY.
// Endpoint: POST https://api.valyu.ai/v1/search (we ONLY use /v1/search —
//   never /v1/deepsearch, Answer, or DeepResearch).
//
// The result shape below is drop-in compatible with the old exaSearch
// consumers: each result exposes .id/.url/.title/.score/.publishedDate.

import type { Bindings } from "../env.js";
import { vendorFetch } from "../vendor.js";

const BASE = "https://api.valyu.ai";

export interface ValyuSearchOptions {
  query: string;
  numResults?: number;
  /** Per-tenant cache namespacing; pass the authed user id. */
  tenant: string;
  ctx?: ExecutionContext;
}

export interface ValyuResult {
  id: string;
  url: string;
  title: string;
  content?: string;
  score?: number;
  publishedDate?: string;
  price?: number;
  source?: string;
}

export interface ValyuSearchResponse {
  results: ValyuResult[];
}

/** Raw shape of a single Valyu /v1/search result item. */
interface ValyuRawResult {
  title: string;
  url: string;
  content?: string;
  source?: string;
  relevance_score?: number;
  publication_date?: string;
  price?: number;
}

export async function valyuSearch(
  env: Bindings,
  opts: ValyuSearchOptions,
): Promise<ValyuSearchResponse> {
  if (!env.VALYU_API_KEY) {
    throw new Error("VALYU_API_KEY is not configured on the worker");
  }
  const body = JSON.stringify({
    query: opts.query,
    search_type: "web",
    max_num_results: opts.numResults ?? 10,
    max_price: 20,
    fast_mode: true,
    is_tool_call: true,
  });
  const res = await vendorFetch(env, {
    provider: "valyu",
    tenant: opts.tenant,
    url: `${BASE}/v1/search`,
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": env.VALYU_API_KEY,
    },
    body,
    cacheTtl: 1800,
    rateLimit: 30,
    metadata: { query: opts.query },
    ctx: opts.ctx,
  });
  if (!res.ok) {
    throw new Error(`Valyu search ${res.status}: ${await res.text()}`);
  }
  const data = (await res.json()) as { results?: ValyuRawResult[] };
  return {
    results: (data.results ?? []).map((r) => ({
      id: r.url,
      url: r.url,
      title: r.title,
      content: r.content,
      score: r.relevance_score,
      publishedDate: r.publication_date,
      price: r.price,
      source: r.source,
    })),
  };
}
