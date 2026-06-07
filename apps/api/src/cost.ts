// Per-request cost telemetry.
//
// A CostTracker accumulates line items recording WHAT was billed for
// THIS request: which provider was hit, how many calls, what tokens (if
// LLM), what tier (if fetchBrand). The tracker can render itself as a
// `[brandnana-cost]` marker string that the CLI emits to stderr and the
// shim parses into a sidecar JSON file.
//
// Marker format (line-regex parseable):
//   [brandnana-cost] usd_at_cost=0.0083 usd_with_margin=0.0125 capability=resolve sources=exa,wiki,llm exa_calls=1 llm_input_tokens=420 llm_output_tokens=89 model=meta-llama/llama-3.2-3b-instruct
//
// The legacy form `[brandnana-cost] usd=N capability=NAME` is still
// emitted as a prefix so older parsers continue to read the at-cost
// figure into `usd`.

import { llmCallCostUsd, resolveMargin } from "./pricing.js";

// ── Line-item shapes ─────────────────────────────────────────────────────────

export type CostLineItem =
  | { kind: "exa"; calls: number; usd: number }
  | { kind: "valyu"; calls: number; usd: number }
  | { kind: "wikipedia"; calls: number; usd: number }
  | {
      kind: "llm";
      model: string;
      prompt_tokens: number;
      completion_tokens: number;
      usd: number;
      /** True when usd came from upstream (OpenRouter usage.cost). False when computed from our rate table. */
      from_upstream: boolean;
    }
  | { kind: "fetch"; tier: string; calls: number; usd: number }
  | { kind: "other"; provider: string; calls: number; usd: number };

export interface CostMarker {
  /** Capability name — e.g. "resolve", "brand/fetch". */
  capability: string;
  /** Sum of all line items, at-cost (our actual upstream spend). */
  usd_at_cost: number;
  /** usd_at_cost × margin (what the user pays). */
  usd_with_margin: number;
  /** Margin multiplier in effect when the marker was emitted. */
  margin: number;
  items: CostLineItem[];
}

// ── CostTracker ──────────────────────────────────────────────────────────────

export class CostTracker {
  private items: CostLineItem[] = [];

  /**
   * Record an Exa search call. usdPerRequest comes from pricing.ts.
   * DEPRECATED: Exa is removed from the request path; kept for back-compat
   * with any rollback path. New web-search billing uses addValyuCall.
   */
  addExaCall(usdPerRequest: number, calls = 1): void {
    this.items.push({ kind: "exa", calls, usd: usdPerRequest * calls });
  }

  /** Record a Valyu /v1/search call. usdPerRequest is supplied by the caller. */
  addValyuCall(usdPerRequest: number, calls = 1): void {
    this.items.push({ kind: "valyu", calls, usd: usdPerRequest * calls });
  }

  /** Record a Wikipedia API call (free, but recorded for visibility). */
  addWikipediaCall(calls = 1): void {
    this.items.push({ kind: "wikipedia", calls, usd: 0 });
  }

  /**
   * Record an LLM call. If `upstreamUsd` is provided (e.g. from
   * OpenRouter's usage.cost field), that value is authoritative.
   * Otherwise we compute from the rate table in pricing.ts.
   */
  addLlmCall(
    model: string,
    usage: { prompt_tokens: number; completion_tokens: number } | undefined,
    upstreamUsd?: number,
  ): void {
    if (!usage) return;
    if (typeof upstreamUsd === "number" && Number.isFinite(upstreamUsd)) {
      this.items.push({
        kind: "llm",
        model,
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        usd: upstreamUsd,
        from_upstream: true,
      });
      return;
    }
    const computed = llmCallCostUsd(model, usage);
    if (computed === null) {
      // Unknown model — record zero with a flag so audit can surface it.
      this.items.push({
        kind: "llm",
        model,
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        usd: 0,
        from_upstream: false,
      });
      return;
    }
    this.items.push({
      kind: "llm",
      model,
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      usd: computed,
      from_upstream: false,
    });
  }

  /** Record a fetchBrand tier call. usdPerCall comes from pricing.ts. */
  addFetchTier(tier: string, usdPerCall: number, calls = 1): void {
    this.items.push({ kind: "fetch", tier, calls, usd: usdPerCall * calls });
  }

  /** Record a generic upstream provider call when none of the kinds above fit. */
  addOther(provider: string, usdPerCall: number, calls = 1): void {
    this.items.push({ kind: "other", provider, calls, usd: usdPerCall * calls });
  }

  /** Get the raw line items (for tests / debugging). */
  getItems(): readonly CostLineItem[] {
    return this.items;
  }

  /** Sum of all at-cost line items. */
  totalAtCost(): number {
    let sum = 0;
    for (const it of this.items) sum += it.usd;
    return sum;
  }

  /**
   * Build a CostMarker payload. `margin` defaults to resolveMargin(env)
   * if not passed; pass an env object so the tracker can pick up
   * BRANDNANA_COST_MARGIN at marker time.
   */
  buildMarker(
    capability: string,
    env?: { BRANDNANA_COST_MARGIN?: string },
    overrideMargin?: number,
  ): CostMarker {
    const margin = typeof overrideMargin === "number" ? overrideMargin : resolveMargin(env);
    const atCost = this.totalAtCost();
    return {
      capability,
      usd_at_cost: round6(atCost),
      usd_with_margin: round6(atCost * margin),
      margin,
      items: [...this.items],
    };
  }
}

// ── Marker formatting ────────────────────────────────────────────────────────

function round6(n: number): number {
  return Math.round(n * 1_000_000) / 1_000_000;
}

/**
 * Render a CostMarker as the stderr marker line. Format is line-regex
 * parseable: leading `[brandnana-cost]` token, then key=value pairs
 * separated by single spaces. Each value contains no spaces — we
 * comma-separate list-valued fields like sources=exa,wiki.
 */
export function formatCostMarker(marker: CostMarker): string {
  const parts: string[] = ["[brandnana-cost]"];

  // Legacy `usd=` key first so older parsers still match.
  parts.push(`usd=${marker.usd_at_cost.toFixed(6)}`);
  parts.push(`usd_at_cost=${marker.usd_at_cost.toFixed(6)}`);
  parts.push(`usd_with_margin=${marker.usd_with_margin.toFixed(6)}`);
  parts.push(`margin=${marker.margin.toFixed(2)}`);
  parts.push(`capability=${marker.capability}`);

  // Aggregate breakdown.
  const sources = new Set<string>();
  let exaCalls = 0;
  let valyuCalls = 0;
  let wikiCalls = 0;
  const fetchTiers = new Map<string, number>();
  let llmInTokens = 0;
  let llmOutTokens = 0;
  const llmModels = new Set<string>();
  const llmFromUpstream = new Set<boolean>();
  const otherProviders = new Map<string, number>();

  for (const it of marker.items) {
    switch (it.kind) {
      case "exa":
        sources.add("exa");
        exaCalls += it.calls;
        break;
      case "valyu":
        sources.add("valyu");
        valyuCalls += it.calls;
        break;
      case "wikipedia":
        sources.add("wiki");
        wikiCalls += it.calls;
        break;
      case "fetch":
        sources.add(`fetch:${it.tier}`);
        fetchTiers.set(it.tier, (fetchTiers.get(it.tier) ?? 0) + it.calls);
        break;
      case "llm":
        sources.add("llm");
        llmInTokens += it.prompt_tokens;
        llmOutTokens += it.completion_tokens;
        llmModels.add(it.model);
        llmFromUpstream.add(it.from_upstream);
        break;
      case "other":
        sources.add(it.provider);
        otherProviders.set(it.provider, (otherProviders.get(it.provider) ?? 0) + it.calls);
        break;
    }
  }

  if (sources.size > 0) parts.push(`sources=${Array.from(sources).sort().join(",")}`);
  if (exaCalls > 0) parts.push(`exa_calls=${exaCalls}`);
  if (valyuCalls > 0) parts.push(`valyu_calls=${valyuCalls}`);
  if (wikiCalls > 0) parts.push(`wiki_calls=${wikiCalls}`);
  for (const [tier, n] of fetchTiers) {
    parts.push(`fetch_${tier.replace(/-/g, "_")}_calls=${n}`);
  }
  if (llmInTokens > 0 || llmOutTokens > 0) {
    parts.push(`llm_input_tokens=${llmInTokens}`);
    parts.push(`llm_output_tokens=${llmOutTokens}`);
    if (llmModels.size > 0) parts.push(`model=${Array.from(llmModels).join(",")}`);
    if (llmFromUpstream.has(true) && !llmFromUpstream.has(false)) {
      parts.push("llm_cost_source=upstream");
    } else if (llmFromUpstream.has(false) && !llmFromUpstream.has(true)) {
      parts.push("llm_cost_source=computed");
    } else if (llmFromUpstream.size === 2) {
      parts.push("llm_cost_source=mixed");
    }
  }
  for (const [provider, n] of otherProviders) {
    parts.push(`${provider}_calls=${n}`);
  }

  return parts.join(" ");
}

// ── Marker parsing (used by audit-trace) ─────────────────────────────────────

export interface ParsedCostMarker {
  capability: string;
  usd_at_cost: number;
  usd_with_margin: number;
  margin: number;
  raw: string;
  extra: Record<string, string>;
}

const MARKER_PREFIX = "[brandnana-cost]";

/**
 * Parse a single `[brandnana-cost]` marker line into a structured
 * record. Returns null when the line isn't a valid marker or lacks
 * a parseable `usd_at_cost` (or legacy `usd`) and `capability`.
 *
 * Robust to extra whitespace and to extra key=value pairs the
 * formatter may have added that the audit code doesn't know about.
 */
export function parseCostMarker(line: string): ParsedCostMarker | null {
  const trimmed = line.trim();
  if (!trimmed.startsWith(MARKER_PREFIX)) return null;
  const tail = trimmed.slice(MARKER_PREFIX.length).trim();
  const kv: Record<string, string> = {};
  for (const tok of tail.split(/\s+/)) {
    const eq = tok.indexOf("=");
    if (eq <= 0) continue;
    const k = tok.slice(0, eq);
    const v = tok.slice(eq + 1);
    kv[k] = v;
  }
  const capability = kv.capability;
  if (!capability) return null;
  // Prefer the explicit at_cost / with_margin; fall back to the legacy
  // `usd=` value (treat it as both at-cost and user-facing).
  const usdAtCostRaw = kv.usd_at_cost ?? kv.usd;
  if (usdAtCostRaw === undefined) return null;
  const usdAtCost = Number.parseFloat(usdAtCostRaw);
  if (!Number.isFinite(usdAtCost)) return null;
  const usdWithMargin = Number.parseFloat(kv.usd_with_margin ?? usdAtCostRaw);
  const margin = Number.parseFloat(kv.margin ?? "1.0");
  return {
    capability,
    usd_at_cost: usdAtCost,
    usd_with_margin: Number.isFinite(usdWithMargin) ? usdWithMargin : usdAtCost,
    margin: Number.isFinite(margin) ? margin : 1.0,
    raw: trimmed,
    extra: kv,
  };
}
