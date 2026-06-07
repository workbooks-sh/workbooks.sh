// `brandnana audit-trace <workdir>` — reads a finished eval's
// .brandnana-trace.jsonl and prints which brandnana capabilities
// were and were NOT exercised, plus LIVE cost telemetry pulled from
// .brandnana-cost.jsonl (wb-fcq2).
//
// NOT pass/fail — pure visibility into what happened.
// Pairs with AUDIT.md which is the canonical capability map.

import { existsSync, readFileSync } from "node:fs";
import { basename, resolve } from "node:path";
import type { Command } from "commander";
import { emit, emitError } from "../output.js";

// ── Trace record ────────────────────────────────────────────────────────────

interface TraceRecord {
  ts: string;
  argv: string[];
  duration_ms: number;
  exit: number;
  stdout_bytes: number;
  stderr_bytes: number;
}

// ── Cost sidecar record (written by the brandnana-traced shim) ──────────────

interface CostRecord {
  ts: string;
  argv: string[];
  capability: string;
  usd_at_cost: number;
  usd_with_margin: number;
  margin: number;
  extras?: Record<string, string>;
  raw?: string;
}

// ── Capability map ───────────────────────────────────────────────────────────
//
// Each entry maps a capability ID (stable string) to the argv prefix(es) that
// identify a call to that capability. argv[0] is the binary name (brandnana)
// and is skipped in matching — we match from argv[1] onward.
//
// `verbs` is an ordered list: every element must appear in the argv at its
// corresponding position for the pattern to match. E.g. ["social", "instagram",
// "profile"] matches argv = ["brandnana", "social", "instagram", "profile", ...]
//
// NOTE (wb-fcq2): we used to carry a `cost_per_call` field here as a
// static lookup. That table is gone — costs now come from the live
// `[brandnana-cost]` markers each capability emits, captured by the
// brandnana-traced shim into .brandnana-cost.jsonl. Capabilities that
// ran but didn't emit a marker show up as a telemetry-hole WARN in the
// audit report so we know which CLI commands still need wiring.

interface CapabilitySpec {
  id: string;
  label: string;
  verbs: string[];
}

const CAPABILITIES: CapabilitySpec[] = [
  // Domain resolution — run FIRST when a brief names a brand without a domain
  { id: "resolve", label: "resolve", verbs: ["resolve"] },

  // Core research trio — required by brandnana_research_done gate
  { id: "brief", label: "brief", verbs: ["brief"] },
  { id: "brand/fetch", label: "brand fetch", verbs: ["brand", "fetch"] },
  { id: "ads/search", label: "ads search", verbs: ["ads", "search"] },

  // ads
  { id: "ads/sync", label: "ads sync", verbs: ["ads", "sync"] },

  // brand
  { id: "brand/styleguide", label: "brand styleguide", verbs: ["brand", "styleguide"] },
  { id: "brand/fonts", label: "brand fonts", verbs: ["brand", "fonts"] },
  { id: "brand/screenshot", label: "brand screenshot", verbs: ["brand", "screenshot"] },

  // catalog
  { id: "catalog/crawl", label: "catalog crawl", verbs: ["catalog", "crawl"] },

  // design
  { id: "design/tokens", label: "design tokens", verbs: ["design", "tokens"] },

  // logo
  { id: "logo", label: "logo", verbs: ["logo"] },

  // auth (free)
  { id: "auth/meta", label: "auth meta", verbs: ["auth", "meta"] },
  { id: "auth/tiktok", label: "auth tiktok", verbs: ["auth", "tiktok"] },
  { id: "auth/google", label: "auth google", verbs: ["auth", "google"] },
  { id: "auth/status", label: "auth status", verbs: ["auth", "status"] },

  // usage (free)
  { id: "usage", label: "usage", verbs: ["usage"] },

  // social — Instagram
  {
    id: "social/instagram/profile",
    label: "social instagram profile",
    verbs: ["social", "instagram", "profile"],
  },
  {
    id: "social/instagram/posts",
    label: "social instagram posts",
    verbs: ["social", "instagram", "posts"],
  },
  {
    id: "social/instagram/reels",
    label: "social instagram reels",
    verbs: ["social", "instagram", "reels"],
  },
  {
    id: "social/instagram/transcript",
    label: "social instagram transcript",
    verbs: ["social", "instagram", "transcript"],
  },

  // social — TikTok
  {
    id: "social/tiktok/profile",
    label: "social tiktok profile",
    verbs: ["social", "tiktok", "profile"],
  },
  {
    id: "social/tiktok/videos",
    label: "social tiktok videos",
    verbs: ["social", "tiktok", "videos"],
  },
  {
    id: "social/tiktok/search",
    label: "social tiktok search",
    verbs: ["social", "tiktok", "search"],
  },
  {
    id: "social/tiktok/trending",
    label: "social tiktok trending",
    verbs: ["social", "tiktok", "trending"],
  },

  // social — YouTube
  {
    id: "social/youtube/channel",
    label: "social youtube channel",
    verbs: ["social", "youtube", "channel"],
  },
  {
    id: "social/youtube/videos",
    label: "social youtube videos",
    verbs: ["social", "youtube", "videos"],
  },
  {
    id: "social/youtube/search",
    label: "social youtube search",
    verbs: ["social", "youtube", "search"],
  },
  {
    id: "social/youtube/transcript",
    label: "social youtube transcript",
    verbs: ["social", "youtube", "transcript"],
  },

  // social — Twitter
  {
    id: "social/twitter/profile",
    label: "social twitter profile",
    verbs: ["social", "twitter", "profile"],
  },
  {
    id: "social/twitter/tweets",
    label: "social twitter tweets",
    verbs: ["social", "twitter", "tweets"],
  },

  // social — Facebook
  {
    id: "social/facebook/profile",
    label: "social facebook profile",
    verbs: ["social", "facebook", "profile"],
  },
  {
    id: "social/facebook/posts",
    label: "social facebook posts",
    verbs: ["social", "facebook", "posts"],
  },

  // social — LinkedIn
  { id: "social/linkedin/ads", label: "social linkedin ads", verbs: ["social", "linkedin", "ads"] },
  {
    id: "social/linkedin/company",
    label: "social linkedin company",
    verbs: ["social", "linkedin", "company"],
  },

  // social — Reddit
  {
    id: "social/reddit/search",
    label: "social reddit search",
    verbs: ["social", "reddit", "search"],
  },
  {
    id: "social/reddit/subreddit",
    label: "social reddit subreddit",
    verbs: ["social", "reddit", "subreddit"],
  },

  // social — TikTok Shop
  { id: "social/tiktok-shop", label: "social tiktok-shop", verbs: ["social", "tiktok-shop"] },

  // social — Pinterest
  { id: "social/pinterest", label: "social pinterest", verbs: ["social", "pinterest"] },

  // social — others
  { id: "social/bluesky", label: "social bluesky", verbs: ["social", "bluesky"] },
  { id: "social/threads", label: "social threads", verbs: ["social", "threads"] },
  { id: "social/spotify", label: "social spotify", verbs: ["social", "spotify"] },
  { id: "social/google", label: "social google", verbs: ["social", "google"] },
  { id: "social/twitch", label: "social twitch", verbs: ["social", "twitch"] },
  { id: "social/soundcloud", label: "social soundcloud", verbs: ["social", "soundcloud"] },
  { id: "social/links", label: "social links", verbs: ["social", "links"] },
];

/**
 * Capabilities that are explicitly free upstream — emitting no marker
 * for one of these is not a telemetry hole.
 */
const FREE_CAPABILITIES = new Set<string>([
  "ads/sync",
  "auth/meta",
  "auth/tiktok",
  "auth/google",
  "auth/status",
  "usage",
]);

// ── Trace file resolution ────────────────────────────────────────────────────

function resolveTraceFile(workdir: string): string | null {
  const brandnanaPath = resolve(workdir, ".brandnana-trace.jsonl");
  if (existsSync(brandnanaPath)) return brandnanaPath;
  return null;
}

function resolveCostFile(workdir: string): string | null {
  const p = resolve(workdir, ".brandnana-cost.jsonl");
  return existsSync(p) ? p : null;
}

// ── Record parsing ───────────────────────────────────────────────────────────

function parseTrace(tracePath: string): TraceRecord[] {
  const raw = readFileSync(tracePath, "utf-8");
  const records: TraceRecord[] = [];
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const r = JSON.parse(trimmed) as TraceRecord;
      if (Array.isArray(r.argv) && r.argv.length > 0) {
        records.push(r);
      }
    } catch {
      // skip malformed lines
    }
  }
  return records;
}

function parseCostLog(costPath: string): CostRecord[] {
  const raw = readFileSync(costPath, "utf-8");
  const records: CostRecord[] = [];
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const r = JSON.parse(trimmed) as CostRecord;
      if (typeof r.capability === "string" && typeof r.usd_at_cost === "number") {
        records.push(r);
      }
    } catch {
      // skip malformed lines
    }
  }
  return records;
}

// ── Capability matching ──────────────────────────────────────────────────────

/**
 * Returns true when a trace record's argv matches the given capability spec.
 *
 * argv[0] is the binary name (brandnana) — skipped.
 * Then each `verbs` element must match argv[1], argv[2], … in order.
 * Extra trailing args (domain names, flags) are ignored.
 */
function argvMatchesCapability(argv: string[], cap: CapabilitySpec): boolean {
  for (let i = 0; i < cap.verbs.length; i++) {
    if (argv[i + 1] !== cap.verbs[i]) return false;
  }
  return true;
}

/**
 * Match a single trace record to the most specific capability whose verbs
 * fit its argv. Returns null when nothing matches.
 *
 * "Most specific" = longest verbs[] prefix that matches. Without this,
 * `brandnana brand fetch` would also match `brandnana brand`.
 */
function bestMatchingCapability(argv: string[]): CapabilitySpec | null {
  let best: CapabilitySpec | null = null;
  for (const cap of CAPABILITIES) {
    if (!argvMatchesCapability(argv, cap)) continue;
    if (!best || cap.verbs.length > best.verbs.length) best = cap;
  }
  return best;
}

/**
 * Returns true when a call is a "real" brandnana invocation rather than
 * a help probe or a failed no-op. Mirrors the gate logic in trace.rs:
 *   - exit 0
 *   - no --help in argv
 *   - stdout_bytes >= 256 (non-trivial payload)
 */
function isRealCall(rec: TraceRecord): boolean {
  if (rec.exit !== 0) return false;
  if (rec.argv.some((a) => a === "--help" || a === "-h")) return false;
  if ((rec.stdout_bytes ?? 0) < 256) return false;
  return true;
}

// ── Report types ─────────────────────────────────────────────────────────────

interface CapabilityResult {
  id: string;
  label: string;
  used: boolean;
  calls: number;
  /** Sum of usd_at_cost from cost markers attributed to this capability. */
  usd_at_cost: number;
  /** Sum of usd_with_margin from cost markers attributed to this capability. */
  usd_with_margin: number;
  /** Calls that ran (matched argv) but emitted no `[brandnana-cost]` marker. */
  calls_missing_telemetry: number;
}

interface AuditReport {
  workdir: string;
  trace_file: string;
  cost_file: string | null;
  capabilities: CapabilityResult[];
  totals: {
    calls: number;
    exercised: number;
    total_capabilities: number;
    usd_at_cost: number;
    usd_with_margin: number;
    calls_missing_telemetry: number;
  };
  /** Margin in effect when the cost log was written. May be 1.0 when no markers exist. */
  effective_margin: number;
  warnings: string[];
}

// ── Core audit logic ─────────────────────────────────────────────────────────

/**
 * Build the audit report from a list of trace records + cost markers.
 * All capabilities are listed regardless of whether they were used —
 * that's the whole point of the tool.
 */
function buildReport(
  workdir: string,
  tracePath: string,
  costPath: string | null,
  traceRecords: TraceRecord[],
  costRecords: CostRecord[],
): AuditReport {
  // Index cost records by capability — multiple markers may exist for
  // the same capability across separate CLI invocations; sum them.
  const costByCapability = new Map<string, CostRecord[]>();
  for (const rec of costRecords) {
    const arr = costByCapability.get(rec.capability) ?? [];
    arr.push(rec);
    costByCapability.set(rec.capability, arr);
  }

  // Count real CLI calls per capability from the trace file.
  const realCallsByCapability = new Map<string, number>();
  for (const rec of traceRecords) {
    if (!isRealCall(rec)) continue;
    const cap = bestMatchingCapability(rec.argv);
    if (!cap) continue;
    realCallsByCapability.set(cap.id, (realCallsByCapability.get(cap.id) ?? 0) + 1);
  }

  const results: CapabilityResult[] = [];
  const warnings: string[] = [];
  let totalCalls = 0;
  let totalMissing = 0;
  let totalAtCost = 0;
  let totalWithMargin = 0;
  let marginObs = 0;
  let marginSum = 0;

  for (const cap of CAPABILITIES) {
    const calls = realCallsByCapability.get(cap.id) ?? 0;
    const markers = costByCapability.get(cap.id) ?? [];
    let atCost = 0;
    let withMargin = 0;
    for (const m of markers) {
      atCost += m.usd_at_cost;
      withMargin += m.usd_with_margin;
      marginSum += m.margin;
      marginObs += 1;
    }

    // Telemetry hole: capability ran (≥1 call) but no marker arrived
    // and the capability is not in FREE_CAPABILITIES.
    let missing = 0;
    if (calls > 0 && markers.length === 0 && !FREE_CAPABILITIES.has(cap.id)) {
      missing = calls;
      warnings.push(
        `telemetry hole: capability '${cap.id}' ran ${calls} time${calls === 1 ? "" : "s"} but emitted no cost marker`,
      );
    } else if (calls > markers.length && !FREE_CAPABILITIES.has(cap.id) && markers.length > 0) {
      missing = calls - markers.length;
      warnings.push(
        `partial telemetry: capability '${cap.id}' ran ${calls} time${calls === 1 ? "" : "s"} but only ${markers.length} cost marker${markers.length === 1 ? "" : "s"} found`,
      );
    }

    totalCalls += calls;
    totalAtCost += atCost;
    totalWithMargin += withMargin;
    totalMissing += missing;

    results.push({
      id: cap.id,
      label: cap.label,
      used: calls > 0,
      calls,
      usd_at_cost: atCost,
      usd_with_margin: withMargin,
      calls_missing_telemetry: missing,
    });
  }

  const exercised = results.filter((r) => r.used).length;
  const effectiveMargin = marginObs > 0 ? marginSum / marginObs : 1.0;

  if (costPath === null && totalCalls > 0) {
    warnings.unshift(
      "no .brandnana-cost.jsonl found — costs reported as $0; ensure the brandnana-traced shim is on PATH",
    );
  }

  return {
    workdir,
    trace_file: tracePath,
    cost_file: costPath,
    capabilities: results,
    totals: {
      calls: totalCalls,
      exercised,
      total_capabilities: CAPABILITIES.length,
      usd_at_cost: totalAtCost,
      usd_with_margin: totalWithMargin,
      calls_missing_telemetry: totalMissing,
    },
    effective_margin: effectiveMargin,
    warnings,
  };
}

// ── Human-readable formatter ─────────────────────────────────────────────────

function formatReport(report: AuditReport): string {
  const name = basename(report.workdir);
  const SEP = "─".repeat(72);
  const lines: string[] = [`brandnana audit for ${name}`, SEP];

  for (const cap of report.capabilities) {
    const check = cap.used ? "✓" : "✗";
    const status = cap.used ? `used (${cap.calls} call${cap.calls === 1 ? "" : "s"})` : "NOT used";
    let cost: string;
    if (!cap.used) {
      cost = "    —";
    } else if (cap.calls_missing_telemetry > 0 && cap.usd_with_margin === 0) {
      cost = "    ?  no telemetry";
    } else if (cap.calls_missing_telemetry > 0) {
      cost = `$${cap.usd_with_margin.toFixed(4)} (partial — ${cap.calls_missing_telemetry} missing)`;
    } else {
      cost = `$${cap.usd_with_margin.toFixed(4)}`;
    }

    const labelPad = cap.label.padEnd(28);
    const statusPad = status.padEnd(24);
    lines.push(`  ${check} ${labelPad}  ${statusPad}  ${cost}`);
  }

  lines.push(SEP);

  if (report.warnings.length > 0) {
    lines.push("  warnings:");
    for (const w of report.warnings) {
      lines.push(`    !  ${w}`);
    }
    lines.push(SEP);
  }

  const margin = report.effective_margin.toFixed(2);
  lines.push(`  total at-cost spend:    $${report.totals.usd_at_cost.toFixed(4)}  (raw upstream)`);
  lines.push(
    `  total user-facing bill: $${report.totals.usd_with_margin.toFixed(4)}  (× ${margin} margin)`,
  );
  lines.push(
    `  ${report.totals.exercised} capabilities exercised of ${report.totals.total_capabilities} total`,
  );
  if (report.totals.calls_missing_telemetry > 0) {
    lines.push(
      `  ${report.totals.calls_missing_telemetry} call${report.totals.calls_missing_telemetry === 1 ? "" : "s"} missing cost telemetry`,
    );
  }

  return lines.join("\n");
}

// ── Command registration ─────────────────────────────────────────────────────

/**
 * Register `brandnana audit-trace <workdir>` with the Commander program.
 *
 * Reads a finished eval's trace file and prints a structured checklist
 * of which brandnana capabilities were and were NOT exercised, plus
 * cost telemetry — sourced from live `[brandnana-cost]` markers, not a
 * static lookup table.
 */
export function registerAuditTrace(program: Command): void {
  program
    .command("audit-trace <workdir>")
    .description(
      "Show which brandnana capabilities were exercised in a finished eval run, with LIVE cost telemetry (reads .brandnana-trace.jsonl + .brandnana-cost.jsonl)",
    )
    .option("--base-url <url>", "Override API base URL (unused; accepted for parity)")
    .action((workdir: string, _opts: { baseUrl?: string }) => {
      const absWorkdir = resolve(process.cwd(), workdir);
      const tracePath = resolveTraceFile(absWorkdir);

      if (!tracePath) {
        emitError(
          new Error(
            `no trace file found in ${absWorkdir}\n  looked for: .brandnana-trace.jsonl\n  the PATH shim writes this file during eval runs`,
          ),
        );
      }

      let records: TraceRecord[];
      try {
        records = parseTrace(tracePath);
      } catch (e) {
        emitError(new Error(`failed to read trace file ${tracePath}: ${(e as Error).message}`));
      }

      const costPath = resolveCostFile(absWorkdir);
      let costRecords: CostRecord[] = [];
      if (costPath) {
        try {
          costRecords = parseCostLog(costPath);
        } catch (e) {
          emitError(new Error(`failed to read cost file ${costPath}: ${(e as Error).message}`));
        }
      }

      const report = buildReport(absWorkdir, tracePath, costPath, records, costRecords);
      emit(report, formatReport(report));
    });
}

// ── Exports for testing ──────────────────────────────────────────────────────

export {
  buildReport,
  bestMatchingCapability,
  CAPABILITIES,
  FREE_CAPABILITIES,
  parseCostLog,
  parseTrace,
};
