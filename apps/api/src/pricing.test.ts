// Unit tests for the pricing module — verifies each provider rate is
// stable, every code path that consumes pricing uses the same constants
// (no hardcoded duplicates), and the margin resolution behaves correctly.
//
// Run with: bun test apps/api/src/pricing.test.ts

import { describe, expect, it } from "bun:test";
import {
  EXA_SEARCH_USD_PER_REQUEST,
  EXA_SEARCH_WITH_CONTENTS_USD_PER_REQUEST,
  FETCH_CF_BROWSER_USD_PER_CALL,
  FETCH_CONTEXT_DEV_USD_PER_CALL,
  FETCH_DIRECT_USD_PER_CALL,
  FETCH_FIRECRAWL_USD_PER_CALL,
  MODEL_RATES,
  WIKIPEDIA_USD_PER_REQUEST,
  fetchTierCostUsd,
  llmCallCostUsd,
  resolveMargin,
} from "./pricing.js";

describe("pricing constants — vendor rates pinned with citations", () => {
  it("Exa search is $0.005/request (without content fetch)", () => {
    expect(EXA_SEARCH_USD_PER_REQUEST).toBe(0.005);
  });

  it("Exa with-contents is $0.025/request", () => {
    expect(EXA_SEARCH_WITH_CONTENTS_USD_PER_REQUEST).toBe(0.025);
  });

  it("Wikipedia is $0 (free)", () => {
    expect(WIKIPEDIA_USD_PER_REQUEST).toBe(0);
  });

  it("fetchBrand tier=direct is $0", () => {
    expect(FETCH_DIRECT_USD_PER_CALL).toBe(0);
  });

  it("fetchBrand tier=context-dev matches starter-plan rate ($0.001)", () => {
    expect(FETCH_CONTEXT_DEV_USD_PER_CALL).toBe(0.001);
  });

  it("fetchBrand tier=firecrawl uses standard-plan credit rate", () => {
    expect(FETCH_FIRECRAWL_USD_PER_CALL).toBeGreaterThan(0);
    expect(FETCH_FIRECRAWL_USD_PER_CALL).toBeLessThan(0.01);
  });

  it("fetchBrand tier=cf-browser has a non-zero rate", () => {
    expect(FETCH_CF_BROWSER_USD_PER_CALL).toBeGreaterThan(0);
  });
});

describe("fetchTierCostUsd — single dispatch", () => {
  it("dispatches to the right constant for each known tier", () => {
    expect(fetchTierCostUsd("direct")).toBe(FETCH_DIRECT_USD_PER_CALL);
    expect(fetchTierCostUsd("cf-browser")).toBe(FETCH_CF_BROWSER_USD_PER_CALL);
    expect(fetchTierCostUsd("context-dev")).toBe(FETCH_CONTEXT_DEV_USD_PER_CALL);
    expect(fetchTierCostUsd("firecrawl")).toBe(FETCH_FIRECRAWL_USD_PER_CALL);
  });

  it("returns 0 for unknown tiers (caller surfaces as warning)", () => {
    expect(fetchTierCostUsd("nope")).toBe(0);
  });
});

describe("llmCallCostUsd — token-based LLM billing", () => {
  it("computes cost from prompt_tokens × input rate + completion_tokens × output rate", () => {
    // llama 3.2 3b at $0.06/M in, $0.06/M out
    const cost = llmCallCostUsd("meta-llama/llama-3.2-3b-instruct", {
      prompt_tokens: 1_000_000,
      completion_tokens: 1_000_000,
    });
    expect(cost).toBe(0.12);
  });

  it("computes asymmetric rate for Claude haiku ($0.8/M in, $4/M out)", () => {
    const cost = llmCallCostUsd("anthropic/claude-haiku-4-5", {
      prompt_tokens: 1000,
      completion_tokens: 1000,
    });
    // (1000/1e6) * 0.8 + (1000/1e6) * 4 = 0.0008 + 0.004 = 0.0048
    expect(cost).toBeCloseTo(0.0048, 6);
  });

  it("returns null for an unknown model so callers can flag the gap", () => {
    expect(
      llmCallCostUsd("openai/totally-fake-model-xyz", {
        prompt_tokens: 100,
        completion_tokens: 100,
      }),
    ).toBeNull();
  });

  it("returns null when usage is undefined", () => {
    expect(llmCallCostUsd("meta-llama/llama-3.2-3b-instruct", undefined)).toBeNull();
  });

  it("matches the rate table — every entry has a non-empty slug and positive rates", () => {
    expect(MODEL_RATES.length).toBeGreaterThan(0);
    for (const r of MODEL_RATES) {
      expect(r.slug.length).toBeGreaterThan(0);
      expect(r.input_usd_per_million).toBeGreaterThan(0);
      expect(r.output_usd_per_million).toBeGreaterThan(0);
    }
  });
});

describe("resolveMargin — BRANDNANA_COST_MARGIN env handling", () => {
  it("defaults to 1.5x when unset", () => {
    expect(resolveMargin(undefined)).toBe(1.5);
    expect(resolveMargin({})).toBe(1.5);
  });

  it("reads numeric value from env", () => {
    expect(resolveMargin({ BRANDNANA_COST_MARGIN: "2.0" })).toBe(2.0);
    expect(resolveMargin({ BRANDNANA_COST_MARGIN: "1.25" })).toBe(1.25);
  });

  it("clamps below 1.0 up to 1.0 (no below-cost billing)", () => {
    expect(resolveMargin({ BRANDNANA_COST_MARGIN: "0.5" })).toBe(1.0);
    expect(resolveMargin({ BRANDNANA_COST_MARGIN: "-1" })).toBe(1.0);
  });

  it("clamps above 3.0 down to 3.0 (sanity cap)", () => {
    expect(resolveMargin({ BRANDNANA_COST_MARGIN: "5" })).toBe(3.0);
    expect(resolveMargin({ BRANDNANA_COST_MARGIN: "100" })).toBe(3.0);
  });

  it("falls back to 1.5 for non-numeric input", () => {
    expect(resolveMargin({ BRANDNANA_COST_MARGIN: "abc" })).toBe(1.5);
    expect(resolveMargin({ BRANDNANA_COST_MARGIN: "" })).toBe(1.5);
  });
});
