// Unit tests for the CostTracker / marker formatter / marker parser.
//
// Run with: bun test apps/api/src/cost.test.ts

import { describe, expect, it } from "bun:test";
import { CostTracker, formatCostMarker, parseCostMarker } from "./cost.js";
import { EXA_SEARCH_USD_PER_REQUEST, FETCH_CONTEXT_DEV_USD_PER_CALL } from "./pricing.js";

describe("CostTracker — accumulates billable line items", () => {
  it("tracks Exa calls and sums correctly", () => {
    const c = new CostTracker();
    c.addExaCall(EXA_SEARCH_USD_PER_REQUEST, 2);
    expect(c.totalAtCost()).toBeCloseTo(0.01, 6);
  });

  it("tracks Valyu calls and sums correctly", () => {
    const c = new CostTracker();
    c.addValyuCall(0.0015, 2);
    expect(c.totalAtCost()).toBeCloseTo(0.003, 6);
    expect(c.getItems()[0]).toMatchObject({ kind: "valyu", calls: 2 });
  });

  it("tracks Wikipedia calls as free ($0)", () => {
    const c = new CostTracker();
    c.addWikipediaCall(3);
    expect(c.totalAtCost()).toBe(0);
    expect(c.getItems()).toHaveLength(1);
  });

  it("tracks LLM cost from upstream when provided", () => {
    const c = new CostTracker();
    c.addLlmCall(
      "meta-llama/llama-3.2-3b-instruct",
      { prompt_tokens: 100, completion_tokens: 100 },
      0.0042,
    );
    expect(c.totalAtCost()).toBe(0.0042);
    const items = c.getItems();
    expect(items[0]).toMatchObject({ kind: "llm", from_upstream: true, usd: 0.0042 });
  });

  it("falls back to computed LLM cost when upstream cost is absent", () => {
    const c = new CostTracker();
    c.addLlmCall("meta-llama/llama-3.2-3b-instruct", {
      prompt_tokens: 1_000_000,
      completion_tokens: 1_000_000,
    });
    // 1M in × $0.06/M + 1M out × $0.06/M = $0.12
    expect(c.totalAtCost()).toBeCloseTo(0.12, 6);
    const items = c.getItems();
    expect(items[0]).toMatchObject({ kind: "llm", from_upstream: false });
  });

  it("records unknown model with usd=0 + from_upstream=false (telemetry flag)", () => {
    const c = new CostTracker();
    c.addLlmCall("unknown/model", { prompt_tokens: 50, completion_tokens: 50 });
    expect(c.totalAtCost()).toBe(0);
    const items = c.getItems();
    expect(items[0]).toMatchObject({ kind: "llm", from_upstream: false, usd: 0 });
  });

  it("ignores LLM calls with no usage info", () => {
    const c = new CostTracker();
    c.addLlmCall("meta-llama/llama-3.2-3b-instruct", undefined);
    expect(c.getItems()).toHaveLength(0);
  });

  it("tracks fetchBrand tier calls with the right per-tier rate", () => {
    const c = new CostTracker();
    c.addFetchTier("context-dev", FETCH_CONTEXT_DEV_USD_PER_CALL, 3);
    expect(c.totalAtCost()).toBeCloseTo(0.003, 6);
  });

  it("aggregates across multiple sources", () => {
    const c = new CostTracker();
    c.addExaCall(EXA_SEARCH_USD_PER_REQUEST, 1); // 0.005
    c.addWikipediaCall(1); // 0
    c.addFetchTier("direct", 0, 5); // 0
    c.addLlmCall("meta-llama/llama-3.2-3b-instruct", {
      prompt_tokens: 1000,
      completion_tokens: 500,
    }); // (1000/1e6)*0.06 + (500/1e6)*0.06 = 0.00006 + 0.00003 = 0.00009
    expect(c.totalAtCost()).toBeCloseTo(0.005 + 0.00009, 6);
  });
});

describe("CostTracker.buildMarker — assembles the marker payload", () => {
  it("returns capability, at-cost, with-margin, margin, and items", () => {
    const c = new CostTracker();
    c.addExaCall(EXA_SEARCH_USD_PER_REQUEST, 2);
    const marker = c.buildMarker("resolve", undefined, 2.0);
    expect(marker.capability).toBe("resolve");
    expect(marker.usd_at_cost).toBeCloseTo(0.01, 6);
    expect(marker.usd_with_margin).toBeCloseTo(0.02, 6);
    expect(marker.margin).toBe(2.0);
    expect(marker.items).toHaveLength(1);
  });

  it("uses resolveMargin(env) when no override is passed", () => {
    const c = new CostTracker();
    c.addExaCall(EXA_SEARCH_USD_PER_REQUEST, 1);
    const marker = c.buildMarker("resolve", { BRANDNANA_COST_MARGIN: "2.5" });
    expect(marker.margin).toBe(2.5);
    expect(marker.usd_with_margin).toBeCloseTo(marker.usd_at_cost * 2.5, 6);
  });

  it("defaults margin to 1.5 when env is missing", () => {
    const c = new CostTracker();
    c.addExaCall(EXA_SEARCH_USD_PER_REQUEST, 1);
    const marker = c.buildMarker("resolve");
    expect(marker.margin).toBe(1.5);
  });
});

describe("formatCostMarker — line-regex parseable output", () => {
  it("emits the legacy `[brandnana-cost] usd=…` prefix", () => {
    const c = new CostTracker();
    c.addExaCall(EXA_SEARCH_USD_PER_REQUEST, 1);
    const line = formatCostMarker(c.buildMarker("resolve", undefined, 1.5));
    expect(line.startsWith("[brandnana-cost] ")).toBe(true);
    expect(line).toMatch(/\busd=0\.005000\b/);
    expect(line).toMatch(/\bcapability=resolve\b/);
  });

  it("includes usd_at_cost, usd_with_margin, and margin", () => {
    const c = new CostTracker();
    c.addExaCall(EXA_SEARCH_USD_PER_REQUEST, 2);
    const line = formatCostMarker(c.buildMarker("resolve", undefined, 1.5));
    expect(line).toContain("usd_at_cost=0.010000");
    expect(line).toContain("usd_with_margin=0.015000");
    expect(line).toContain("margin=1.50");
  });

  it("aggregates sources, exa_calls, llm tokens", () => {
    const c = new CostTracker();
    c.addExaCall(EXA_SEARCH_USD_PER_REQUEST, 1);
    c.addWikipediaCall(1);
    c.addLlmCall("meta-llama/llama-3.2-3b-instruct", { prompt_tokens: 420, completion_tokens: 89 });
    const line = formatCostMarker(c.buildMarker("resolve"));
    expect(line).toContain("sources=exa,llm,wiki");
    expect(line).toContain("exa_calls=1");
    expect(line).toContain("wiki_calls=1");
    expect(line).toContain("llm_input_tokens=420");
    expect(line).toContain("llm_output_tokens=89");
    expect(line).toContain("model=meta-llama/llama-3.2-3b-instruct");
  });

  it("aggregates valyu source + valyu_calls", () => {
    const c = new CostTracker();
    c.addValyuCall(0.0015, 1);
    c.addWikipediaCall(1);
    const line = formatCostMarker(c.buildMarker("resolve"));
    expect(line).toContain("sources=valyu,wiki");
    expect(line).toContain("valyu_calls=1");
  });

  it("encodes fetchBrand tier breakdown", () => {
    const c = new CostTracker();
    c.addFetchTier("context-dev", FETCH_CONTEXT_DEV_USD_PER_CALL, 2);
    const line = formatCostMarker(c.buildMarker("brand/fetch"));
    expect(line).toContain("sources=fetch:context-dev");
    expect(line).toContain("fetch_context_dev_calls=2");
  });

  it("has no internal whitespace in any key=value token", () => {
    const c = new CostTracker();
    c.addExaCall(EXA_SEARCH_USD_PER_REQUEST, 1);
    c.addLlmCall("meta-llama/llama-3.2-3b-instruct", {
      prompt_tokens: 5,
      completion_tokens: 5,
    });
    const line = formatCostMarker(c.buildMarker("resolve"));
    const tokens = line.split(" ");
    expect(tokens[0]).toBe("[brandnana-cost]");
    for (const t of tokens.slice(1)) {
      expect(t).not.toContain(" ");
      expect(t).toContain("=");
    }
  });
});

describe("parseCostMarker — robust line-regex parser", () => {
  it("parses a fully-formed marker", () => {
    const line =
      "[brandnana-cost] usd=0.005000 usd_at_cost=0.005000 usd_with_margin=0.007500 margin=1.50 capability=resolve sources=exa exa_calls=1";
    const parsed = parseCostMarker(line);
    expect(parsed).not.toBeNull();
    expect(parsed?.capability).toBe("resolve");
    expect(parsed?.usd_at_cost).toBe(0.005);
    expect(parsed?.usd_with_margin).toBe(0.0075);
    expect(parsed?.margin).toBe(1.5);
    expect(parsed?.extra.exa_calls).toBe("1");
  });

  it("parses a legacy `usd=0.04 capability=resolve` marker (no with_margin)", () => {
    const line = "[brandnana-cost] usd=0.04 capability=resolve";
    const parsed = parseCostMarker(line);
    expect(parsed?.capability).toBe("resolve");
    expect(parsed?.usd_at_cost).toBe(0.04);
    expect(parsed?.usd_with_margin).toBe(0.04);
    expect(parsed?.margin).toBe(1.0);
  });

  it("returns null for lines without the prefix", () => {
    expect(parseCostMarker("[other] usd=1.0 capability=resolve")).toBeNull();
    expect(parseCostMarker("nothing to see here")).toBeNull();
  });

  it("returns null when capability is missing", () => {
    expect(parseCostMarker("[brandnana-cost] usd=0.04")).toBeNull();
  });

  it("returns null when no usd_at_cost or usd field is present", () => {
    expect(parseCostMarker("[brandnana-cost] capability=resolve")).toBeNull();
  });

  it("tolerates extra whitespace and unknown keys", () => {
    const line = "   [brandnana-cost]   usd=0.005   capability=resolve  some_future_key=hello   ";
    const parsed = parseCostMarker(line);
    expect(parsed?.capability).toBe("resolve");
    expect(parsed?.extra.some_future_key).toBe("hello");
  });
});

describe("end-to-end — format then parse round-trips", () => {
  it("formatCostMarker output is parseable by parseCostMarker", () => {
    const c = new CostTracker();
    c.addExaCall(EXA_SEARCH_USD_PER_REQUEST, 1);
    c.addWikipediaCall(1);
    c.addLlmCall("meta-llama/llama-3.2-3b-instruct", { prompt_tokens: 420, completion_tokens: 89 });
    const marker = c.buildMarker("resolve", undefined, 1.5);
    const line = formatCostMarker(marker);
    const parsed = parseCostMarker(line);
    expect(parsed).not.toBeNull();
    expect(parsed?.capability).toBe("resolve");
    expect(parsed?.usd_at_cost).toBeCloseTo(marker.usd_at_cost, 6);
    expect(parsed?.usd_with_margin).toBeCloseTo(marker.usd_with_margin, 6);
    expect(parsed?.margin).toBe(1.5);
    expect(parsed?.extra.sources).toContain("exa");
    expect(parsed?.extra.sources).toContain("llm");
    expect(parsed?.extra.sources).toContain("wiki");
  });
});
