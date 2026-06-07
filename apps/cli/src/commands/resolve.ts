// `brandnana resolve <query>` — find the canonical domain for an ambiguous
// brand reference.
//
// Invocation:
//   brandnana resolve <query> [--json] [--limit N]
//
// Returns ranked candidate domains for an ambiguous brand reference.
// The API server runs the probes (direct-guess, Exa, Wikipedia, LLM).
//
// Output shape (--json):
// {
//   "query": "livconscious",
//   "candidates": [
//     {
//       "domain": "weliveconscious.com",
//       "confidence": 0.85,
//       "source": "web_search",
//       "rationale": "Top Exa result — matches as compound form 'we live conscious'",
//       "verified": true
//     }
//   ],
//   "recommended": 0,
//   "rejected": [
//     { "domain": "livconscious.com", "reason": "homepage_404" }
//   ]
// }

import { VERBS } from "@brandnana/schema";
import type { ResolveCost, ResolveResult } from "@brandnana/sdk";
import type { Command } from "commander";
import { clientFromEnv } from "../client.js";
import { emit, runAction, warn } from "../output.js";

function verbSummary(id: string): string {
  return VERBS.find((v) => v.id === id)?.summary ?? id;
}

// ── Cost marker formatting ───────────────────────────────────────────────────
//
// Mirrors apps/api/src/cost.ts formatCostMarker(). We re-format on the
// CLI side so the marker that lands in the trace sidecar reflects what
// the user-facing process actually saw — and so older parsers that match
// on `[brandnana-cost] usd=N capability=X` keep working when newer keys
// are present.

function formatCostMarker(cost: ResolveCost): string {
  const parts: string[] = [
    "[brandnana-cost]",
    `usd=${cost.usd_at_cost.toFixed(6)}`,
    `usd_at_cost=${cost.usd_at_cost.toFixed(6)}`,
    `usd_with_margin=${cost.usd_with_margin.toFixed(6)}`,
    `margin=${cost.margin.toFixed(2)}`,
    `capability=${cost.capability}`,
  ];

  const sources = new Set<string>();
  let exaCalls = 0;
  let wikiCalls = 0;
  const fetchTiers = new Map<string, number>();
  let llmIn = 0;
  let llmOut = 0;
  const llmModels = new Set<string>();

  for (const it of cost.items) {
    const item = it as Record<string, unknown>;
    switch (item.kind) {
      case "exa":
        sources.add("exa");
        exaCalls += typeof item.calls === "number" ? item.calls : 0;
        break;
      case "wikipedia":
        sources.add("wiki");
        wikiCalls += typeof item.calls === "number" ? item.calls : 0;
        break;
      case "fetch": {
        const tier = typeof item.tier === "string" ? item.tier : "unknown";
        sources.add(`fetch:${tier}`);
        const calls = typeof item.calls === "number" ? item.calls : 0;
        fetchTiers.set(tier, (fetchTiers.get(tier) ?? 0) + calls);
        break;
      }
      case "llm":
        sources.add("llm");
        llmIn += typeof item.prompt_tokens === "number" ? item.prompt_tokens : 0;
        llmOut += typeof item.completion_tokens === "number" ? item.completion_tokens : 0;
        if (typeof item.model === "string") llmModels.add(item.model);
        break;
      default:
        if (typeof item.kind === "string") sources.add(item.kind);
    }
  }

  if (sources.size > 0) parts.push(`sources=${Array.from(sources).sort().join(",")}`);
  if (exaCalls > 0) parts.push(`exa_calls=${exaCalls}`);
  if (wikiCalls > 0) parts.push(`wiki_calls=${wikiCalls}`);
  for (const [tier, n] of fetchTiers) {
    parts.push(`fetch_${tier.replace(/-/g, "_")}_calls=${n}`);
  }
  if (llmIn > 0 || llmOut > 0) {
    parts.push(`llm_input_tokens=${llmIn}`);
    parts.push(`llm_output_tokens=${llmOut}`);
    if (llmModels.size > 0) parts.push(`model=${Array.from(llmModels).join(",")}`);
  }

  return parts.join(" ");
}

interface ResolveOptions {
  limit?: string;
  baseUrl?: string;
}

const SOURCE_LABELS: Record<string, string> = {
  direct_guess: "direct",
  web_search: "Exa",
  wikipedia: "Wikipedia",
  llm_fallback: "LLM",
};

function confidenceBar(confidence: number): string {
  const pct = Math.round(confidence * 10);
  return "█".repeat(pct) + "░".repeat(10 - pct);
}

function fmt(result: ResolveResult): string {
  const lines: string[] = [`resolve: ${result.query}`];

  if (result.candidates.length === 0) {
    lines.push("  no candidates found");
  } else {
    lines.push("");
    for (let i = 0; i < result.candidates.length; i++) {
      const c = result.candidates[i];
      if (!c) continue;
      const star = i === result.recommended ? " ★" : "  ";
      const src = SOURCE_LABELS[c.source] ?? c.source;
      const verMark = c.verified ? " ✓" : " ?";
      lines.push(
        `${star} ${i + 1}. ${c.domain.padEnd(32)} ${confidenceBar(c.confidence)} ${(c.confidence * 100).toFixed(0).padStart(3)}%  [${src}]${verMark}`,
      );
      lines.push(`      ${c.rationale}`);
    }
  }

  const recommendedCandidate =
    result.recommended !== null ? result.candidates[result.recommended] : undefined;
  if (recommendedCandidate) {
    lines.push("");
    lines.push(`  recommended: ${recommendedCandidate.domain}`);
  }

  if (result.rejected.length > 0) {
    lines.push("");
    lines.push(`  rejected (${result.rejected.length}):`);
    for (const r of result.rejected.slice(0, 5)) {
      lines.push(`    ✗ ${r.domain}  — ${r.reason}`);
    }
    if (result.rejected.length > 5) {
      lines.push(`    … and ${result.rejected.length - 5} more`);
    }
  }

  return lines.join("\n");
}

export function registerResolve(program: Command): void {
  program
    .command("resolve <query>")
    .description(verbSummary("resolve.query"))
    .option("--limit <n>", "Max candidates to return (default 5, max 10)")
    .option("--base-url <url>", "Override API base URL")
    .action((query: string, opts: ResolveOptions) =>
      runAction(async () => {
        const client = await clientFromEnv(opts.baseUrl);
        const limit = opts.limit ? Number.parseInt(opts.limit, 10) : undefined;
        const result = await client.resolve.query(query, limit);

        if (result.candidates.length === 0) {
          warn(`no candidates found for "${query}"`);
        }

        // Emit cost marker to stderr — sourced from real upstream usage
        // returned by the API in result.cost. Older marker prefix
        // `[brandnana-cost] usd=N capability=resolve` is preserved.
        if (result.cost) {
          process.stderr.write(`${formatCostMarker(result.cost)}\n`);
        } else {
          // No cost field from API (older deployment) → emit a $0 marker
          // with a hint so audit-trace can surface the telemetry hole.
          process.stderr.write(
            "[brandnana-cost] usd=0.0 usd_at_cost=0.0 usd_with_margin=0.0 margin=1.0 capability=resolve telemetry=missing\n",
          );
        }

        emit(result, fmt(result));
      }),
    );
}
