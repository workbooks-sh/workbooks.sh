// POST /v1/resolve — find the canonical domain for an ambiguous brand reference.
//
// Resolution sources (probed in parallel, 5s cap each):
//   1. direct-guess   — common domain patterns + HEAD via fetchBrand()
//   2. web-search     — Valyu "brand official website" web search
//   3. wikipedia      — MediaWiki API infobox website field
//   4. llm-fallback   — last resort: LLM-assisted guess (max 1 call)
//
// Confidence scoring:
//   direct-guess + verified:  +0.40
//   web top result + verified: +0.30
//   wikipedia infobox + verified: +0.30
//   llm fallback verified:    +0.15
//   verification HEAD check:  +0.05
//   compound-form match:      +0.10
//   aggregator/parking:       -0.40 (reject)

import { Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import { type CostMarker, CostTracker, formatCostMarker } from "../cost.js";
import type { Bindings } from "../env.js";
import { chat } from "../llm/openrouter.js";
import { fetchTierCostUsd } from "../pricing.js";
import { fetchBrand } from "../scrape/fetch-brand.js";
import { valyuSearch } from "../scrape/valyu.js";

const resolve = new Hono<{ Bindings: Bindings }>();
resolve.use("*", requireBearer);

// Valyu web search per-request cost. Source: Valyu pricing — web search
// ~$1.50 / 1000 requests = $0.0015 / request. The vendorFetch cache (30-min
// TTL) reduces effective spend; we bill unconditionally per call and rely on
// usage rollups to reflect cache savings.
const VALYU_SEARCH_USD_PER_REQUEST = 0.0015;

// ── Types ────────────────────────────────────────────────────────────────────

export interface ResolveCandidate {
  domain: string;
  confidence: number;
  source: "direct_guess" | "web_search" | "wikipedia" | "llm_fallback";
  rationale: string;
  verified: boolean;
}

export interface ResolveRejected {
  domain: string;
  reason: string;
}

export interface ResolveResult {
  query: string;
  candidates: ResolveCandidate[];
  recommended: number | null;
  rejected: ResolveRejected[];
  /** Live per-call cost breakdown for this resolve invocation. */
  cost: CostMarker;
}

// ── Parking-page detection ────────────────────────────────────────────────────

const PARKING_SIGNATURES = [
  "domain is for sale",
  "buy this domain",
  "this domain is for sale",
  "godaddy.com",
  "sedo.com",
  "dan.com",
  "hugedomains.com",
  "bodis.com",
  "parking",
  "this web page is parked",
  "domain parked",
  "register this domain",
  "get this domain",
];

function isParkingPage(body: string): boolean {
  const lower = body.toLowerCase();
  return PARKING_SIGNATURES.some((sig) => lower.includes(sig));
}

// ── Aggregator / non-brand domain filter ─────────────────────────────────────

const AGGREGATOR_DOMAINS = [
  "wikipedia.org",
  "amazon.com",
  "ebay.com",
  "walmart.com",
  "target.com",
  "yelp.com",
  "yellowpages.com",
  "crunchbase.com",
  "linkedin.com",
  "facebook.com",
  "instagram.com",
  "twitter.com",
  "tiktok.com",
  "youtube.com",
  "reddit.com",
  "pinterest.com",
  "bloomberg.com",
  "forbes.com",
  "businessinsider.com",
  "cnbc.com",
  "techcrunch.com",
  "news.com",
  "indeed.com",
  "glassdoor.com",
  "bbb.org",
  "trustpilot.com",
];

function isAggregator(domain: string): boolean {
  return AGGREGATOR_DOMAINS.some((agg) => domain === agg || domain.endsWith(`.${agg}`));
}

// ── Domain slug normalization ─────────────────────────────────────────────────

function slugify(query: string): string {
  return query
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "")
    .trim();
}

/** Generate candidate domain guesses from a raw query string. */
function generateDomainGuesses(query: string): string[] {
  const slug = slugify(query);
  if (!slug) return [];
  const tlds = [".com", ".co", ".io", ".shop"];
  const prefixes = ["we", "the", "get", "use", "try", "shop"];
  const suffixes = ["shop", "store", "hq"];
  const guesses = new Set<string>();
  // bare + TLDs
  for (const tld of tlds) guesses.add(`${slug}${tld}`);
  // prefix + bare + .com
  for (const pre of prefixes) guesses.add(`${pre}${slug}.com`);
  // slug + suffix + .com
  for (const suf of suffixes) guesses.add(`${slug}${suf}.com`);
  return Array.from(guesses);
}

// ── Compound-form similarity ──────────────────────────────────────────────────

/**
 * Returns true when the domain's SLD (second-level domain) contains the
 * query slug as a substring — catches "weliveconscious" ↔ "livconscious".
 */
function isCompoundForm(query: string, domain: string): boolean {
  const slug = slugify(query);
  const sld = domain.split(".")[0] ?? "";
  return sld.includes(slug) || slug.includes(sld);
}

// ── HEAD-verify a domain ──────────────────────────────────────────────────────

interface VerifyResult {
  ok: boolean;
  isParking: boolean;
  reason?: string;
}

async function verifyDomain(
  env: Bindings,
  domain: string,
  cost: CostTracker,
): Promise<VerifyResult> {
  const url = `https://${domain}`;
  try {
    // Use fetchBrand for WAF bypass; we only need a quick probe
    const result = await fetchBrand(env, url, {
      timeoutMs: 5000,
      skipTiers: ["cf-browser", "context-dev", "firecrawl"],
    });
    cost.addFetchTier(result.source, fetchTierCostUsd(result.source));
    if (!result.ok) {
      // Try www prefix if bare domain fails
      const wwwResult = await fetchBrand(env, `https://www.${domain}`, {
        timeoutMs: 5000,
        skipTiers: ["cf-browser", "context-dev", "firecrawl"],
      });
      cost.addFetchTier(wwwResult.source, fetchTierCostUsd(wwwResult.source));
      if (!wwwResult.ok)
        return { ok: false, isParking: false, reason: `http_${result.status || wwwResult.status}` };
      if (wwwResult.body && isParkingPage(wwwResult.body))
        return { ok: false, isParking: true, reason: "parking_page" };
      return { ok: true, isParking: false };
    }
    if (result.body && isParkingPage(result.body))
      return { ok: false, isParking: true, reason: "parking_page" };
    return { ok: true, isParking: false };
  } catch {
    return { ok: false, isParking: false, reason: "fetch_error" };
  }
}

// ── Source 1: Direct guess ────────────────────────────────────────────────────

async function directGuessSource(
  env: Bindings,
  query: string,
  cost: CostTracker,
): Promise<{ candidates: ResolveCandidate[]; rejected: ResolveRejected[] }> {
  const guesses = generateDomainGuesses(query);
  const candidates: ResolveCandidate[] = [];
  const rejected: ResolveRejected[] = [];

  // Probe all guesses in parallel with individual 5s caps
  const probes = await Promise.all(
    guesses.map(async (domain) => ({ domain, verify: await verifyDomain(env, domain, cost) })),
  );

  for (const { domain, verify } of probes) {
    if (verify.isParking) {
      rejected.push({ domain, reason: "parking_page" });
      continue;
    }
    if (!verify.ok) {
      if (
        verify.reason &&
        (verify.reason.startsWith("http_4") || verify.reason === "homepage_404")
      ) {
        rejected.push({ domain, reason: "homepage_404" });
      }
      continue;
    }
    let confidence = 0.4;
    confidence += 0.05; // verified
    if (isCompoundForm(query, domain)) confidence += 0.1;
    const rationale = `Direct domain pattern match${isCompoundForm(query, domain) ? " — matches query as compound form" : ""}`;
    candidates.push({ domain, confidence, source: "direct_guess", rationale, verified: true });
  }

  return { candidates, rejected };
}

// ── Source 2: Valyu web search ────────────────────────────────────────────────

async function webSearchSource(
  env: Bindings,
  query: string,
  tenant: string,
  ctx: ExecutionContext,
  cost: CostTracker,
): Promise<{ candidates: ResolveCandidate[]; rejected: ResolveRejected[] }> {
  const candidates: ResolveCandidate[] = [];
  const rejected: ResolveRejected[] = [];

  if (!env.VALYU_API_KEY) return { candidates, rejected };

  try {
    const searchQuery = `${query} official website`;
    const result = await valyuSearch(env, {
      query: searchQuery,
      numResults: 10,
      tenant,
      ctx,
    });
    // Valyu /v1/search — one billable request per call. vendorFetch caches
    // the response with a 30-minute TTL; the wrapper doesn't surface cache
    // hit/miss to us here so we bill the request unconditionally and rely on
    // usage rollups to reflect cache savings.
    cost.addValyuCall(VALYU_SEARCH_USD_PER_REQUEST, 1);

    // Deduplicate by domain, cap at 5
    const seen = new Set<string>();
    for (const hit of result.results) {
      if (seen.size >= 5) break;
      let domain: string;
      try {
        domain = new URL(hit.url).hostname.replace(/^www\./, "");
      } catch {
        continue;
      }
      if (seen.has(domain) || isAggregator(domain)) continue;
      seen.add(domain);

      // Verify
      const verify = await verifyDomain(env, domain, cost);
      if (verify.isParking) {
        rejected.push({ domain, reason: "parking_page" });
        continue;
      }
      if (!verify.ok) continue;

      let confidence = 0.3;
      confidence += 0.05; // verified
      if (isCompoundForm(query, domain)) confidence += 0.1;

      const rationale = `Top Valyu result for "${searchQuery}"${hit.title ? ` — "${hit.title}"` : ""}${isCompoundForm(query, domain) ? " — matches query as compound form" : ""}`;
      candidates.push({ domain, confidence, source: "web_search", rationale, verified: true });
    }
  } catch {
    // Valyu failure is non-fatal
  }

  return { candidates, rejected };
}

// ── Source 3: Wikipedia ───────────────────────────────────────────────────────

interface WikiSearchResult {
  query?: {
    search?: Array<{ title: string; snippet?: string }>;
  };
}

interface WikiPage {
  query?: {
    pages?: Record<
      string,
      { title?: string; revisions?: Array<{ slots?: { main?: { "*"?: string } } }> }
    >;
  };
}

function extractWebsiteFromWikitext(wikitext: string): string | null {
  // Match {{infobox ...| website = ... }} patterns
  const patterns = [
    /\|\s*website\s*=\s*\{\{URL\|([^|}]+)/i,
    /\|\s*website\s*=\s*https?:\/\/([^\s|}\]]+)/i,
    /\|\s*homepage\s*=\s*\{\{URL\|([^|}]+)/i,
    /\|\s*homepage\s*=\s*https?:\/\/([^\s|}\]]+)/i,
    /\|\s*url\s*=\s*https?:\/\/([^\s|}\]]+)/i,
  ];
  for (const pat of patterns) {
    const m = wikitext.match(pat);
    if (m?.[1]) {
      const raw = m[1].trim().replace(/\|.*$/, "").trim();
      try {
        const u = new URL(raw.startsWith("http") ? raw : `https://${raw}`);
        return u.hostname.replace(/^www\./, "");
      } catch {
        // clean up without URL parsing
        return raw.replace(/^www\./, "").split("/")[0] ?? null;
      }
    }
  }
  return null;
}

async function wikipediaSource(
  env: Bindings,
  query: string,
  cost: CostTracker,
): Promise<{ candidates: ResolveCandidate[]; rejected: ResolveRejected[] }> {
  const candidates: ResolveCandidate[] = [];
  const rejected: ResolveRejected[] = [];

  try {
    // Step 1: search Wikipedia
    const searchUrl = new URL("https://en.wikipedia.org/w/api.php");
    searchUrl.searchParams.set("action", "query");
    searchUrl.searchParams.set("list", "search");
    searchUrl.searchParams.set("srsearch", query);
    searchUrl.searchParams.set("format", "json");
    searchUrl.searchParams.set("srlimit", "3");

    const searchRes = await fetchBrand(env, searchUrl.toString(), {
      timeoutMs: 5000,
      skipTiers: ["cf-browser", "context-dev", "firecrawl"],
    });
    // Wikipedia API itself is free; the fetchBrand call costs whatever
    // tier resolved it (typically tier=direct → $0).
    cost.addFetchTier(searchRes.source, fetchTierCostUsd(searchRes.source));
    cost.addWikipediaCall(1);
    if (!searchRes.ok || !searchRes.body) return { candidates, rejected };

    const searchData = JSON.parse(searchRes.body) as WikiSearchResult;
    const topHit = searchData.query?.search?.[0];
    if (!topHit) return { candidates, rejected };

    // Step 2: fetch the article wikitext to extract infobox website
    const pageUrl = new URL("https://en.wikipedia.org/w/api.php");
    pageUrl.searchParams.set("action", "query");
    pageUrl.searchParams.set("titles", topHit.title);
    pageUrl.searchParams.set("prop", "revisions");
    pageUrl.searchParams.set("rvprop", "content");
    pageUrl.searchParams.set("rvslots", "main");
    pageUrl.searchParams.set("format", "json");
    pageUrl.searchParams.set("formatversion", "2");

    const pageRes = await fetchBrand(env, pageUrl.toString(), {
      timeoutMs: 5000,
      skipTiers: ["cf-browser", "context-dev", "firecrawl"],
    });
    cost.addFetchTier(pageRes.source, fetchTierCostUsd(pageRes.source));
    cost.addWikipediaCall(1);
    if (!pageRes.ok || !pageRes.body) return { candidates, rejected };

    const pageData = JSON.parse(pageRes.body) as {
      query?: {
        pages?: Array<{ revisions?: Array<{ slots?: { main?: { content?: string } } }> }>;
      };
    };
    const pages = pageData.query?.pages;
    if (!pages) return { candidates, rejected };
    const firstPage = Array.isArray(pages)
      ? pages[0]
      : (Object.values(pages)[0] as
          | { revisions?: Array<{ slots?: { main?: { content?: string } } }> }
          | undefined);
    const wikitext = firstPage?.revisions?.[0]?.slots?.main?.content;
    if (!wikitext) return { candidates, rejected };

    const domain = extractWebsiteFromWikitext(wikitext);
    if (!domain) return { candidates, rejected };

    // Verify
    const verify = await verifyDomain(env, domain, cost);
    if (verify.isParking) {
      rejected.push({ domain, reason: "parking_page" });
      return { candidates, rejected };
    }

    let confidence = 0.3;
    if (verify.ok) confidence += 0.05;
    if (isCompoundForm(query, domain)) confidence += 0.1;

    candidates.push({
      domain,
      confidence,
      source: "wikipedia",
      rationale: `Wikipedia infobox website field for "${topHit.title}"`,
      verified: verify.ok,
    });
  } catch {
    // Wikipedia failure is non-fatal
  }

  return { candidates, rejected };
}

// ── Source 4: LLM fallback ────────────────────────────────────────────────────

interface LlmGuess {
  domain: string;
  confidence: number;
  rationale: string;
}

async function llmFallbackSource(
  env: Bindings,
  query: string,
  existingDomains: string[],
  tenant: string,
  cost: CostTracker,
): Promise<{ candidates: ResolveCandidate[]; rejected: ResolveRejected[] }> {
  const candidates: ResolveCandidate[] = [];
  const rejected: ResolveRejected[] = [];

  if (!env.OPENROUTER_API_KEY) return { candidates, rejected };

  // Skip if we already have good candidates
  if (existingDomains.length >= 2) return { candidates, rejected };

  try {
    const systemPrompt = `You are a brand domain resolver. Given a brand name, product description, or ambiguous query, identify the canonical website domain.

Respond ONLY with valid JSON matching this schema:
{
  "guesses": [
    { "domain": "example.com", "confidence": 0.85, "rationale": "reason" }
  ]
}

Rules:
- domain must be a bare domain (no https://, no trailing slash)
- confidence is 0.0 to 1.0
- rationale is a short sentence explaining why
- return at most 3 guesses, ordered by confidence descending
- never guess aggregator sites (wikipedia, amazon, yelp, linkedin, etc.)
- prefer the brand's own website, not resellers or review sites`;

    const userPrompt = `Find the canonical website domain for: "${query}"${existingDomains.length > 0 ? `\n\nAlready found: ${existingDomains.join(", ")} — suggest alternatives if any.` : ""}`;

    const result = await chat(env, {
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userPrompt },
      ],
      model: "meta-llama/llama-3.2-3b-instruct",
      max_tokens: 256,
      temperature: 0.1,
      response_format: { type: "json_object" },
      tenant,
    });
    // Bill the LLM call using OpenRouter's reported cost when available;
    // otherwise compute from token usage × the model rate.
    cost.addLlmCall(result.model, result.usage, result.upstream_cost_usd);

    let parsed: { guesses?: LlmGuess[] };
    try {
      parsed = JSON.parse(result.content) as { guesses?: LlmGuess[] };
    } catch {
      return { candidates, rejected };
    }

    const guesses = parsed.guesses ?? [];
    for (const guess of guesses.slice(0, 3)) {
      if (!guess.domain || typeof guess.domain !== "string") continue;
      const domain = guess.domain
        .toLowerCase()
        .replace(/^www\./, "")
        .replace(/^https?:\/\//, "");
      if (isAggregator(domain)) continue;

      const verify = await verifyDomain(env, domain, cost);
      if (verify.isParking) {
        rejected.push({ domain, reason: "parking_page" });
        continue;
      }

      let confidence = 0.15;
      if (verify.ok) confidence += 0.05;
      if (isCompoundForm(query, domain)) confidence += 0.1;

      candidates.push({
        domain,
        confidence,
        source: "llm_fallback",
        rationale: guess.rationale ?? "LLM-assisted domain guess",
        verified: verify.ok,
      });
    }
  } catch {
    // LLM failure is non-fatal
  }

  return { candidates, rejected };
}

// ── Merge + rank candidates ───────────────────────────────────────────────────

function mergeCandidates(
  batches: Array<{ candidates: ResolveCandidate[]; rejected: ResolveRejected[] }>,
): { candidates: ResolveCandidate[]; rejected: ResolveRejected[] } {
  const byDomain = new Map<string, ResolveCandidate>();
  const allRejected: ResolveRejected[] = [];

  for (const batch of batches) {
    for (const c of batch.candidates) {
      const existing = byDomain.get(c.domain);
      if (existing) {
        // Merge: take highest confidence, combine rationale
        existing.confidence = Math.min(1.0, existing.confidence + c.confidence * 0.5);
        existing.rationale = `${existing.rationale}; also: ${c.rationale}`;
        if (c.verified) existing.verified = true;
      } else {
        byDomain.set(c.domain, { ...c });
      }
    }
    for (const r of batch.rejected) {
      if (!byDomain.has(r.domain)) {
        allRejected.push(r);
      }
    }
  }

  const candidates = Array.from(byDomain.values()).sort((a, b) => b.confidence - a.confidence);

  // Deduplicate rejected (keep first)
  const rejectedSeen = new Set<string>();
  const deduped = allRejected.filter((r) => {
    if (rejectedSeen.has(r.domain)) return false;
    rejectedSeen.add(r.domain);
    return true;
  });

  return { candidates, rejected: deduped };
}

// ── Route handler ─────────────────────────────────────────────────────────────

resolve.post("/", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    query?: string;
    limit?: number;
  };

  if (!body.query || typeof body.query !== "string" || !body.query.trim()) {
    return c.json({ error: "missing_query" }, 400);
  }

  const query = body.query.trim();
  const limit = Math.min(body.limit ?? 5, 10);
  const user = c.get("user");

  // Run parallel sources with a 5s per-source cap
  const TIMEOUT = 5_000;
  const withTimeout = <T>(p: Promise<T>, fallback: T): Promise<T> =>
    Promise.race([p, new Promise<T>((res) => setTimeout(() => res(fallback), TIMEOUT))]);

  const empty: { candidates: ResolveCandidate[]; rejected: ResolveRejected[] } = {
    candidates: [],
    rejected: [],
  };
  const cost = new CostTracker();

  const [direct, web, wiki] = await Promise.all([
    withTimeout(directGuessSource(c.env, query, cost), empty),
    withTimeout(webSearchSource(c.env, query, user.id, c.executionCtx, cost), empty),
    withTimeout(wikipediaSource(c.env, query, cost), empty),
  ]);

  // Merge what we have; only call LLM if results are sparse
  const merged = mergeCandidates([direct, web, wiki]);
  const existingDomains = merged.candidates.map((c) => c.domain);

  // LLM fallback: only when other sources gave < 2 verified candidates
  const verifiedCount = merged.candidates.filter((c) => c.verified).length;
  let llmBatch = empty;
  if (verifiedCount < 2) {
    llmBatch = await withTimeout(
      llmFallbackSource(c.env, query, existingDomains, user.id, cost),
      empty,
    );
  }

  const final = mergeCandidates([merged, llmBatch]);

  // Cap to limit
  const topCandidates = final.candidates.slice(0, limit);
  const recommended = topCandidates.length > 0 ? 0 : null;

  const marker = cost.buildMarker(
    "resolve",
    c.env as unknown as { BRANDNANA_COST_MARGIN?: string },
  );

  const result: ResolveResult = {
    query,
    candidates: topCandidates,
    recommended,
    rejected: final.rejected,
    cost: marker,
  };

  // Marker line for worker logs. The user-facing marker (with margin)
  // is emitted by the CLI to its own stderr; the trace shim then writes
  // it into the per-run cost sidecar.
  console.error(formatCostMarker(marker));

  return c.json(result);
});

export default resolve;
