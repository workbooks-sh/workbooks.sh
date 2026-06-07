// Per-provider unit pricing — the SINGLE SOURCE OF TRUTH for upstream
// rates. Every number here has a citation comment pointing at the
// vendor's published rate. Code that needs a per-call cost imports from
// this module; never hardcode a price elsewhere.
//
// Rates are pinned-with-citation: vendor pricing pages don't expose a
// machine-readable rate endpoint, so we record the rate, the URL we
// pulled it from, and the date we last verified it. Drift handling:
// when audit-trace surfaces an unusually large bill, the first step is
// to re-verify these numbers against the linked pages.

// ── Margin (user-facing markup over at-cost) ────────────────────────────────

/**
 * Multiplier applied to at-cost figures to derive the user-facing bill.
 * Defaults to 1.5×; overridable per-run via BRANDNANA_COST_MARGIN.
 * Bounded to [1.0, 3.0] — values outside that range are clamped.
 */
export function resolveMargin(env: { BRANDNANA_COST_MARGIN?: string } | undefined): number {
  const raw = env?.BRANDNANA_COST_MARGIN;
  if (!raw) return 1.5;
  const n = Number.parseFloat(raw);
  if (!Number.isFinite(n)) return 1.5;
  return Math.min(3.0, Math.max(1.0, n));
}

// ── Exa ──────────────────────────────────────────────────────────────────────
// Source: https://exa.ai/pricing (verified 2026-05-23)
//   - Search request (neural / keyword / auto, no content): $0.005 / req
//   - Search + contents (text / highlights / summary):       $0.025 / req
//
// We always call /search without contents in brandnana — content fetches go
// through fetchBrand(). So the per-call rate below applies to all Exa hits.

export const EXA_SEARCH_USD_PER_REQUEST = 0.005;
export const EXA_SEARCH_WITH_CONTENTS_USD_PER_REQUEST = 0.025;

// ── Wikipedia ────────────────────────────────────────────────────────────────
// Source: https://www.mediawiki.org/wiki/API:Etiquette (free, no billing).

export const WIKIPEDIA_USD_PER_REQUEST = 0;

// ── fetchBrand tiers ─────────────────────────────────────────────────────────
// fetchBrand() escalates through up to 4 tiers; cost is the rate of the
// tier that actually succeeded (or, for compound bills, the sum of every
// tier that was invoked before success).

/**
 * tier=direct  — plain fetch(). Zero marginal cost (Cloudflare Worker egress
 * is bundled in the Workers Paid plan's request count, which we account for
 * separately under CF_WORKER_USD_PER_REQUEST). $0 attributed per fetchBrand
 * tier=direct call.
 */
export const FETCH_DIRECT_USD_PER_CALL = 0;

/**
 * tier=cf-browser — Cloudflare Workers Browser Rendering.
 *
 * Source: https://developers.cloudflare.com/browser-rendering/platform/pricing/
 * Verified 2026-05-23:
 *   - Workers Paid plan includes 10 browser-hours / month.
 *   - Beyond included: $0.09 per additional browser-hour
 *     (= $0.0015 per browser-minute = $0.000025 per browser-second).
 *
 * We bill at a flat per-call rate matching a typical 5-second navigation
 * (one cf-browser launch + page.goto + page.content). If a call takes
 * longer, the at-cost figure undercounts; if shorter, it overcounts.
 * Wire actual durations into this when fetchBrand surfaces them.
 *
 * Typical cf-browser call ≈ 5s → $0.000125. Round up to $0.0002 to
 * cover the average-overhead session.
 */
export const FETCH_CF_BROWSER_USD_PER_CALL = 0.0002;
export const FETCH_CF_BROWSER_USD_PER_SECOND = 0.000025;

/**
 * tier=context-dev — context.dev /v1/scrape/html.
 *
 * Source: https://context.dev/pricing (verified 2026-05-23).
 * Starter plan: $20 / month for 20k scrapes → $0.001 per scrape.
 * Same rate at higher tiers (volume scaling lowers it, but we pin to
 * starter so audit numbers don't undercount when the operator hasn't
 * upgraded).
 */
export const FETCH_CONTEXT_DEV_USD_PER_CALL = 0.001;

/**
 * tier=firecrawl — Firecrawl /v1/scrape.
 *
 * Source: https://www.firecrawl.dev/pricing (verified 2026-05-23).
 * Hobby plan credit pricing: 1 credit per /scrape, $19 for 3000 credits
 * → $0.00633 per scrape. We use $0.002 here because the brandnana
 * deployment is on the Standard plan ($83 / 100k credits ≈ $0.00083 per
 * credit) — that's the at-cost rate. Update this when the plan changes.
 */
export const FETCH_FIRECRAWL_USD_PER_CALL = 0.002;

// ── Cloudflare Worker request ────────────────────────────────────────────────
// Source: https://developers.cloudflare.com/workers/platform/pricing/
// Verified 2026-05-23. Workers Paid: $5 / 10M requests = $0.0000005 / req.
// Negligible per-call; included for completeness so audit numbers are honest
// even for free-tier capabilities (we still bill the request itself).

export const CF_WORKER_USD_PER_REQUEST = 0.0000005;

// ── LLM models (via OpenRouter) ──────────────────────────────────────────────
// Source: https://openrouter.ai/models (verified 2026-05-23).
//
// Rates are $/1M tokens for prompt (input) and completion (output).
// We use the LIST price (what OpenRouter charges us — OpenRouter passes
// underlying provider prices through with ~5% markup baked in for the
// gateway). When the OpenRouter response includes usage.cost or x-cost
// headers, prefer that over computing from these rates — see openrouter.ts.

export interface ModelRate {
  /** OpenRouter model slug, e.g. "meta-llama/llama-3.2-3b-instruct" */
  slug: string;
  /** USD per 1,000,000 prompt tokens */
  input_usd_per_million: number;
  /** USD per 1,000,000 completion tokens */
  output_usd_per_million: number;
}

export const MODEL_RATES: ModelRate[] = [
  // Meta / Llama
  {
    slug: "meta-llama/llama-3.2-3b-instruct",
    input_usd_per_million: 0.06,
    output_usd_per_million: 0.06,
  },
  {
    slug: "meta-llama/llama-3.3-70b-instruct",
    input_usd_per_million: 0.59,
    output_usd_per_million: 0.79,
  },
  // Anthropic Claude (used by some brandnana brief calls)
  {
    slug: "anthropic/claude-haiku-4-5",
    input_usd_per_million: 0.8,
    output_usd_per_million: 4.0,
  },
  {
    slug: "anthropic/claude-sonnet-4-5",
    input_usd_per_million: 3.0,
    output_usd_per_million: 15.0,
  },
];

/**
 * Compute the at-cost USD for an LLM call given the model slug and token
 * counts from `usage`. Returns null if the model isn't in our rate table
 * (caller should surface the missing model as a telemetry warning).
 */
export function llmCallCostUsd(
  model: string,
  usage: { prompt_tokens: number; completion_tokens: number } | undefined,
): number | null {
  if (!usage) return null;
  const rate = MODEL_RATES.find((r) => r.slug === model);
  if (!rate) return null;
  const inCost = (usage.prompt_tokens / 1_000_000) * rate.input_usd_per_million;
  const outCost = (usage.completion_tokens / 1_000_000) * rate.output_usd_per_million;
  return inCost + outCost;
}

/**
 * Look up the per-call USD rate for a fetchBrand tier. Defaults to 0 for
 * unknown tiers so we never silently overcount on a new tier name; the
 * cost tracker logs unknown tiers as warnings.
 */
export function fetchTierCostUsd(tier: string): number {
  switch (tier) {
    case "direct":
      return FETCH_DIRECT_USD_PER_CALL;
    case "cf-browser":
      return FETCH_CF_BROWSER_USD_PER_CALL;
    case "context-dev":
      return FETCH_CONTEXT_DEV_USD_PER_CALL;
    case "firecrawl":
      return FETCH_FIRECRAWL_USD_PER_CALL;
    case "exa-fallback":
      return EXA_SEARCH_USD_PER_REQUEST;
    default:
      return 0;
  }
}
