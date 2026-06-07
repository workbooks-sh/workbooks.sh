// DEPRECATED — Exa has been removed from the brandnana request path.
//
// General web research now goes through scrape/valyu.ts (valyuSearch); ad
// intelligence goes through ScrapeCreators ad-library helpers. This module
// is retained ONLY as a rollback safety net and has no importers. Do NOT
// wire it back into a handler — repoint to valyuSearch instead.
//
// Exa wrapper. Used for search-style discovery (competitors, brand
// mentions, ad-creative discovery via web search).
//
// Docs: https://docs.exa.ai
// Auth: x-api-key header, key in env.EXA_API_KEY.

import type { Bindings } from "../env.js";
import { vendorFetch } from "../vendor.js";

const BASE = "https://api.exa.ai";

export interface ExaSearchOptions {
  query: string;
  numResults?: number;
  type?: "auto" | "neural" | "keyword";
  /** Per-tenant cache namespacing; pass the authed user id. */
  tenant: string;
  ctx?: ExecutionContext;
}

export interface ExaSearchResult {
  id: string;
  url: string;
  title: string;
  publishedDate?: string;
  author?: string;
  score?: number;
}

export interface ExaSearchResponse {
  results: ExaSearchResult[];
  autopromptString?: string;
  resolvedSearchType?: string;
}

export async function exaSearch(env: Bindings, opts: ExaSearchOptions): Promise<ExaSearchResponse> {
  if (!env.EXA_API_KEY) {
    throw new Error("EXA_API_KEY is not configured on the worker");
  }
  const body = JSON.stringify({
    query: opts.query,
    numResults: opts.numResults ?? 10,
    type: opts.type ?? "auto",
  });
  const res = await vendorFetch(env, {
    provider: "exa",
    tenant: opts.tenant,
    url: `${BASE}/search`,
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": env.EXA_API_KEY,
    },
    body,
    cacheTtl: 1800,
    rateLimit: 30,
    metadata: { query: opts.query },
    ctx: opts.ctx,
  });
  if (!res.ok) {
    throw new Error(`Exa search ${res.status}: ${await res.text()}`);
  }
  return (await res.json()) as ExaSearchResponse;
}
