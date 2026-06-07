// Unit tests for audit-trace — verifies live cost telemetry replaces
// the old static cost_per_call table (wb-fcq2).
//
// Run with: bun test apps/cli/src/commands/audit-trace.test.ts

import { describe, expect, it } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  CAPABILITIES,
  FREE_CAPABILITIES,
  bestMatchingCapability,
  buildReport,
  parseCostLog,
  parseTrace,
} from "./audit-trace.js";

// ── Capability matching ─────────────────────────────────────────────────────

describe("bestMatchingCapability — argv → capability dispatch", () => {
  it("matches `brandnana resolve <q>` to the resolve capability", () => {
    const cap = bestMatchingCapability(["brandnana", "resolve", "livconscious"]);
    expect(cap?.id).toBe("resolve");
  });

  it("matches the longest-prefix capability when multiple specs share a prefix", () => {
    // brandnana brand fetch <domain> should match brand/fetch (verbs:
    // ["brand","fetch"]) rather than any single-verb spec.
    const cap = bestMatchingCapability(["brandnana", "brand", "fetch", "example.com"]);
    expect(cap?.id).toBe("brand/fetch");
  });

  it("matches three-verb capabilities (social/instagram/profile)", () => {
    const cap = bestMatchingCapability(["brandnana", "social", "instagram", "profile", "nike"]);
    expect(cap?.id).toBe("social/instagram/profile");
  });

  it("returns null when no capability matches", () => {
    const cap = bestMatchingCapability(["brandnana", "totally-fake-verb"]);
    expect(cap).toBeNull();
  });
});

describe("CAPABILITIES table — no static cost_per_call left", () => {
  it("no entry carries a cost_per_call field anymore (wb-fcq2)", () => {
    for (const cap of CAPABILITIES) {
      expect(cap as unknown as Record<string, unknown>).not.toHaveProperty("cost_per_call");
    }
  });

  it("FREE_CAPABILITIES set lists every $0 verb", () => {
    expect(FREE_CAPABILITIES.has("auth/meta")).toBe(true);
    expect(FREE_CAPABILITIES.has("auth/status")).toBe(true);
    expect(FREE_CAPABILITIES.has("usage")).toBe(true);
    expect(FREE_CAPABILITIES.has("ads/sync")).toBe(true);
  });
});

// ── End-to-end report build ─────────────────────────────────────────────────

function makeWorkdir(
  traceLines: string[],
  costLines: string[],
): {
  workdir: string;
  tracePath: string;
  costPath: string;
} {
  const workdir = mkdtempSync(join(tmpdir(), "audit-test-"));
  const tracePath = join(workdir, ".brandnana-trace.jsonl");
  const costPath = join(workdir, ".brandnana-cost.jsonl");
  writeFileSync(tracePath, `${traceLines.join("\n")}\n`);
  writeFileSync(costPath, `${costLines.join("\n")}\n`);
  return { workdir, tracePath, costPath };
}

describe("buildReport — live cost aggregation", () => {
  it("sums usd_at_cost and usd_with_margin per capability from the sidecar", () => {
    const traceLines = [
      JSON.stringify({
        ts: "2026-05-23T00:00:00Z",
        argv: ["brandnana", "resolve", "livconscious"],
        duration_ms: 1234,
        exit: 0,
        stdout_bytes: 1024,
        stderr_bytes: 64,
      }),
      JSON.stringify({
        ts: "2026-05-23T00:00:01Z",
        argv: ["brandnana", "resolve", "allbirds"],
        duration_ms: 800,
        exit: 0,
        stdout_bytes: 1024,
        stderr_bytes: 64,
      }),
    ];
    const costLines = [
      JSON.stringify({
        ts: "2026-05-23T00:00:00Z",
        argv: ["brandnana", "resolve", "livconscious"],
        capability: "resolve",
        usd_at_cost: 0.006,
        usd_with_margin: 0.009,
        margin: 1.5,
        extras: { sources: "exa,wiki", exa_calls: "1" },
      }),
      JSON.stringify({
        ts: "2026-05-23T00:00:01Z",
        argv: ["brandnana", "resolve", "allbirds"],
        capability: "resolve",
        usd_at_cost: 0.005,
        usd_with_margin: 0.0075,
        margin: 1.5,
        extras: {},
      }),
    ];

    const { workdir, tracePath, costPath } = makeWorkdir(traceLines, costLines);
    const trace = parseTrace(tracePath);
    const cost = parseCostLog(costPath);
    const report = buildReport(workdir, tracePath, costPath, trace, cost);

    const resolveRow = report.capabilities.find((r) => r.id === "resolve");
    expect(resolveRow).toBeDefined();
    expect(resolveRow?.calls).toBe(2);
    expect(resolveRow?.usd_at_cost).toBeCloseTo(0.011, 6);
    expect(resolveRow?.usd_with_margin).toBeCloseTo(0.0165, 6);
    expect(resolveRow?.calls_missing_telemetry).toBe(0);

    expect(report.totals.usd_at_cost).toBeCloseTo(0.011, 6);
    expect(report.totals.usd_with_margin).toBeCloseTo(0.0165, 6);
    expect(report.effective_margin).toBe(1.5);
  });

  it("surfaces telemetry holes: real call with no cost marker → WARN", () => {
    const traceLines = [
      JSON.stringify({
        ts: "2026-05-23T00:00:00Z",
        argv: ["brandnana", "brand", "fetch", "example.com"],
        duration_ms: 500,
        exit: 0,
        stdout_bytes: 1024,
        stderr_bytes: 0,
      }),
    ];
    const costLines: string[] = []; // no markers

    const { workdir, tracePath, costPath } = makeWorkdir(traceLines, costLines);
    const report = buildReport(
      workdir,
      tracePath,
      costPath,
      parseTrace(tracePath),
      parseCostLog(costPath),
    );

    const row = report.capabilities.find((r) => r.id === "brand/fetch");
    expect(row?.calls).toBe(1);
    expect(row?.usd_at_cost).toBe(0);
    expect(row?.calls_missing_telemetry).toBe(1);
    expect(report.warnings.some((w) => w.includes("brand/fetch"))).toBe(true);
  });

  it("does NOT warn on telemetry-free capabilities (auth/status, usage, etc.)", () => {
    const traceLines = [
      JSON.stringify({
        ts: "2026-05-23T00:00:00Z",
        argv: ["brandnana", "auth", "status"],
        duration_ms: 200,
        exit: 0,
        stdout_bytes: 1024,
        stderr_bytes: 0,
      }),
      JSON.stringify({
        ts: "2026-05-23T00:00:00Z",
        argv: ["brandnana", "usage"],
        duration_ms: 100,
        exit: 0,
        stdout_bytes: 1024,
        stderr_bytes: 0,
      }),
    ];
    const { workdir, tracePath, costPath } = makeWorkdir(traceLines, []);
    const report = buildReport(
      workdir,
      tracePath,
      costPath,
      parseTrace(tracePath),
      parseCostLog(costPath),
    );

    expect(report.warnings.some((w) => w.includes("auth/status"))).toBe(false);
    expect(report.warnings.some((w) => w.includes("'usage'"))).toBe(false);
  });

  it("ignores --help probes and stdout_bytes<256 noise", () => {
    const traceLines = [
      JSON.stringify({
        ts: "2026-05-23T00:00:00Z",
        argv: ["brandnana", "resolve", "--help"],
        duration_ms: 5,
        exit: 0,
        stdout_bytes: 1024,
        stderr_bytes: 0,
      }),
      JSON.stringify({
        ts: "2026-05-23T00:00:01Z",
        argv: ["brandnana", "resolve", "x"],
        duration_ms: 5,
        exit: 0,
        stdout_bytes: 12, // < 256
        stderr_bytes: 0,
      }),
    ];
    const { workdir, tracePath, costPath } = makeWorkdir(traceLines, []);
    const report = buildReport(
      workdir,
      tracePath,
      costPath,
      parseTrace(tracePath),
      parseCostLog(costPath),
    );
    const row = report.capabilities.find((r) => r.id === "resolve");
    expect(row?.calls).toBe(0);
    expect(row?.used).toBe(false);
  });

  it("warns when there's no cost sidecar but trace has real calls", () => {
    const traceLines = [
      JSON.stringify({
        ts: "2026-05-23T00:00:00Z",
        argv: ["brandnana", "resolve", "x"],
        duration_ms: 100,
        exit: 0,
        stdout_bytes: 1024,
        stderr_bytes: 0,
      }),
    ];
    const { workdir, tracePath } = makeWorkdir(traceLines, []);
    const report = buildReport(
      workdir,
      tracePath,
      null, // no cost sidecar at all
      parseTrace(tracePath),
      [],
    );
    expect(report.warnings.some((w) => w.includes("no .brandnana-cost.jsonl"))).toBe(true);
  });
});
