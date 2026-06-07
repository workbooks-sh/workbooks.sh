// brandnana admin <subcommand>
//
// Requires BRANDNANA_ADMIN_KEY env or ~/.config/brandnana/admin-key file.
//
// Subcommands:
//   admin health
//   admin spend [--from <date>] [--to <date>] [--group-by <key>] [--json]
//   admin rates [--tag <tag>] [--verb <id>] [--json]
//   admin rates propose --verb <id> --strategy <s> [--multiplier <n>] [--price <usd>] [--notes <s>]
//   admin rates tag <id> <tag>
//   admin events [--verb <id>] [--from <date>] [--limit <n>] [--json]

import type { Command } from "commander";
import {
  AdminClient,
  fetchHealth,
  makeAdminClient,
  type SpendBucket,
  type EventItem,
  type VendorRateCard,
  type CustomerRateCard,
} from "../admin-client.js";
import { emit, emitError, runAction, say } from "../output.js";

// ── Date parsing ──────────────────────────────────────────────────────────────

/**
 * Parse a date string into a Unix timestamp in seconds (for query params).
 *
 * Accepts:
 *   - ISO date: "2026-05-21"   → midnight UTC on that day
 *   - Relative: "-7d", "-24h", "-30m" → ms relative to now
 *   - "now" or empty → Date.now()
 */
export function parseDate(input: string | undefined): number | undefined {
  if (!input || input === "now") return undefined;

  // Relative: -7d / -24h / -30m
  const relMatch = input.match(/^-(\d+)(d|h|m)$/);
  if (relMatch) {
    const n = parseInt(relMatch[1] ?? "0", 10);
    const unit = relMatch[2] ?? "d";
    const msMap: Record<string, number> = { d: 86400_000, h: 3600_000, m: 60_000 };
    return Math.floor((Date.now() - n * (msMap[unit] ?? 86400_000)) / 1000);
  }

  // ISO date "2026-05-21"
  const isoMatch = input.match(/^\d{4}-\d{2}-\d{2}$/);
  if (isoMatch) {
    return Math.floor(new Date(`${input}T00:00:00Z`).getTime() / 1000);
  }

  // ISO datetime
  const d = new Date(input);
  if (!isNaN(d.getTime())) return Math.floor(d.getTime() / 1000);

  throw new Error(`Cannot parse date: ${input}. Use ISO date (2026-05-21) or relative (-7d, -24h, -30m).`);
}

function tsParam(input: string | undefined): string | undefined {
  const ts = parseDate(input);
  return ts !== undefined ? String(ts) : undefined;
}

// ── Formatting helpers ────────────────────────────────────────────────────────

function usd(n: number | undefined): string {
  if (n === undefined || n === null) return "     -";
  return `$${n.toFixed(4)}`;
}

function usdNarrow(n: number | undefined): string {
  if (n === undefined || n === null) return "      -";
  return `$${n.toFixed(4)}`;
}

/** Build a fixed-column-width text table.
 *
 * headers: string[] — column headers
 * rows:    string[][] — rows (each cell is pre-formatted string)
 * widths:  number[] — min column widths (auto-expanded to fit content)
 */
function formatTable(headers: string[], rows: string[][], align?: ("left" | "right")[]): string {
  const cols = headers.length;
  const widths = headers.map((h, i) => {
    let w = h.length;
    for (const row of rows) {
      w = Math.max(w, (row[i] ?? "").length);
    }
    return w;
  });

  function padCell(s: string, col: number): string {
    const a = align?.[col] ?? "left";
    const w = widths[col] ?? s.length;
    return a === "right" ? s.padStart(w) : s.padEnd(w);
  }

  const sep = widths.map((w) => "-".repeat(w)).join("  ");
  const headerLine = headers.map((h, i) => padCell(h, i)).join("  ");
  const dataLines = rows.map((row) =>
    row.map((cell, i) => padCell(cell ?? "", i)).join("  "),
  );

  return [headerLine, sep, ...dataLines].join("\n");
}

// Format a Unix timestamp (seconds) or ISO string to a readable local date-time.
function fmtTs(ts: string | number | undefined): string {
  if (!ts) return "-";
  const d = typeof ts === "number" ? new Date(ts * 1000) : new Date(ts);
  return d.toISOString().replace("T", " ").replace(/\.\d+Z$/, "Z");
}

// ── health ─────────────────────────────────────────────────────────────────────

function registerHealth(admin: Command): void {
  admin
    .command("health")
    .description("Check admin worker health (no auth required)")
    .action(() =>
      runAction(async () => {
        const res = await fetchHealth();
        emit(res, JSON.stringify(res, null, 2));
      }),
    );
}

// ── spend ─────────────────────────────────────────────────────────────────────

function formatSpend(
  res: { buckets: SpendBucket[]; totals: { calls: number; vendor_cost_usd: number; customer_charge_usd: number; margin_usd: number } },
  from: string | undefined,
  to: string | undefined,
  groupBy: string,
): string {
  const fromLabel = from ?? "-7d";
  const toLabel = to ?? "now";

  const dash = "-".repeat(50);
  const lines: string[] = [
    `spend                from ${fromLabel} to ${toLabel}`,
    dash,
    `${"total calls".padEnd(24)}: ${res.totals.calls}`,
    `${"vendor cost".padEnd(24)}: ${usd(res.totals.vendor_cost_usd)}`,
    `${"customer charge".padEnd(24)}: ${usd(res.totals.customer_charge_usd)}`,
    `${"margin".padEnd(24)}: ${usd(res.totals.margin_usd)}`,
    "",
  ];

  if (res.buckets.length > 0) {
    const headers = [groupBy.padEnd(12), "calls", "vendor", "charge", "margin"];
    const align: ("left" | "right")[] = ["left", "right", "right", "right", "right"];
    const rows = res.buckets.map((b) => [
      String(b.key ?? "").slice(0, 12),
      String(b.calls),
      usd(b.vendor_cost_usd),
      usd(b.customer_charge_usd),
      usd(b.margin_usd),
    ]);
    lines.push(formatTable(headers, rows, align));
  } else {
    lines.push("(no data)");
  }

  return lines.join("\n");
}

function registerSpend(admin: Command): void {
  admin
    .command("spend")
    .description("Show spend breakdown")
    .option("--from <date>", "Start date (ISO or relative: -7d, -24h)", "-7d")
    .option("--to <date>", "End date (ISO or relative or 'now')", "now")
    .option("--group-by <key>", "Grouping: day | verb | provider | source", "day")
    .action(
      (opts: { from: string; to: string; groupBy: string }) =>
        runAction(async () => {
          const client = makeAdminClient();
          const res = await client.spend({
            from: tsParam(opts.from),
            to: tsParam(opts.to === "now" ? undefined : opts.to),
            group_by: opts.groupBy,
          });
          emit(res, formatSpend(res, opts.from, opts.to, opts.groupBy));
        }),
    );
}

// ── rates ─────────────────────────────────────────────────────────────────────

function formatVendorRates(cards: VendorRateCard[]): string {
  if (cards.length === 0) return "  (no vendor rate cards)";
  const headers = ["id", "provider", "model", "unit", "price/unit", "source"];
  const align: ("left" | "right")[] = ["left", "left", "left", "left", "right", "left"];
  const rows = cards.map((c) => [
    c.id.slice(0, 24),
    c.provider,
    (c.model ?? "-").slice(0, 24),
    c.unit,
    usdNarrow(c.price_usd_per_unit),
    (c.source ?? "-").slice(0, 12),
  ]);
  return formatTable(headers, rows, align);
}

function formatCustomerRates(cards: CustomerRateCard[]): string {
  if (cards.length === 0) return "  (no customer rate cards)";
  const headers = ["id", "verb_id", "strategy", "multiplier", "fixed_price", "tag", "notes"];
  const align: ("left" | "right")[] = ["left", "left", "left", "right", "right", "left", "left"];
  const rows = cards.map((c) => [
    c.id.slice(0, 20),
    c.verb_id,
    c.price_strategy,
    c.markup_multiplier != null ? String(c.markup_multiplier) : "-",
    c.fixed_price_usd != null ? usdNarrow(c.fixed_price_usd) : "-",
    c.tag ?? "-",
    (c.notes ?? "-").slice(0, 30),
  ]);
  return formatTable(headers, rows, align);
}

function registerRates(admin: Command): void {
  const rates = admin
    .command("rates")
    .description("List or manage rate cards");

  // Default action: list
  rates
    .option("--tag <tag>", "Filter by tag")
    .option("--verb <id>", "Filter by verb ID")
    .action(
      (opts: { tag?: string; verb?: string }) =>
        runAction(async () => {
          const client = makeAdminClient();
          const res = await client.rates({ tag: opts.tag, verb: opts.verb });

          const summary = [
            "vendor rate cards",
            formatVendorRates(res.vendor),
            "",
            "customer rate cards",
            formatCustomerRates(res.customer),
          ].join("\n");

          emit(res, summary);
        }),
    );

  // propose
  rates
    .command("propose")
    .description("Propose a new customer rate card")
    .requiredOption("--verb <id>", "Verb ID")
    .requiredOption(
      "--strategy <s>",
      "Pricing strategy: markup_multiplier | fixed_per_call | fixed_per_unit",
    )
    .option("--multiplier <n>", "Markup multiplier (for markup_multiplier strategy)")
    .option("--price <usd>", "Fixed price in USD (for fixed_per_call / fixed_per_unit)")
    .option("--notes <s>", "Human notes")
    .option("--supersedes <id>", "ID of the rate card this supersedes")
    .action(
      (opts: {
        verb: string;
        strategy: string;
        multiplier?: string;
        price?: string;
        notes?: string;
        supersedes?: string;
      }) =>
        runAction(async () => {
          if (
            opts.strategy !== "markup_multiplier" &&
            opts.strategy !== "fixed_per_call" &&
            opts.strategy !== "fixed_per_unit"
          ) {
            throw new Error(
              `--strategy must be markup_multiplier | fixed_per_call | fixed_per_unit (got: ${opts.strategy})`,
            );
          }

          const client = makeAdminClient();
          const card = await client.ratesPropose({
            verb_id: opts.verb,
            price_strategy: opts.strategy as "markup_multiplier" | "fixed_per_call" | "fixed_per_unit",
            markup_multiplier: opts.multiplier !== undefined ? parseFloat(opts.multiplier) : undefined,
            fixed_price_usd: opts.price !== undefined ? parseFloat(opts.price) : undefined,
            notes: opts.notes,
            effective_from: Math.floor(Date.now() / 1000),
            supersedes_id: opts.supersedes,
          });

          emit(card, `created rate card: ${card.id}`);
        }),
    );

  // tag
  rates
    .command("tag <id> <tag>")
    .description("Freeze a customer rate card with a tag")
    .action((id: string, tag: string) =>
      runAction(async () => {
        const client = makeAdminClient();
        const res = await client.ratesTag(id, tag);
        emit(res, `tagged ${id} as ${tag}`);
      }),
    );
}

// ── events ────────────────────────────────────────────────────────────────────

function formatEvents(items: EventItem[]): string {
  if (items.length === 0) return "(no events)";
  const headers = ["ts", "verb", "source", "status", "dur_ms", "vendor", "charge"];
  const align: ("left" | "right")[] = ["left", "left", "left", "left", "right", "right", "right"];
  const rows = items.map((e) => [
    fmtTs(e.ts),
    e.verb_id,
    e.source ?? "-",
    e.status,
    e.duration_ms != null ? String(e.duration_ms) : "-",
    e.vendor_cost_usd != null ? usd(e.vendor_cost_usd) : "-",
    e.customer_charge_usd != null ? usd(e.customer_charge_usd) : "-",
  ]);
  return formatTable(headers, rows, align);
}

function registerEvents(admin: Command): void {
  admin
    .command("events")
    .description("List recent events")
    .option("--verb <id>", "Filter by verb ID")
    .option("--from <date>", "Start date (ISO or relative: -7d, -24h)")
    .option("--to <date>", "End date")
    .option("--limit <n>", "Max results (default 25)", "25")
    .option("--cursor <s>", "Pagination cursor")
    .action(
      (opts: {
        verb?: string;
        from?: string;
        to?: string;
        limit: string;
        cursor?: string;
      }) =>
        runAction(async () => {
          const client = makeAdminClient();
          const res = await client.events({
            verb: opts.verb,
            from: tsParam(opts.from),
            to: tsParam(opts.to),
            limit: parseInt(opts.limit, 10),
            cursor: opts.cursor,
          });

          const summary = formatEvents(res.items);
          const footer =
            res.next_cursor ? `\nnext cursor: ${res.next_cursor}` : "";

          emit(res, summary + footer);
        }),
    );
}

// ── Register ──────────────────────────────────────────────────────────────────

export function registerAdmin(program: Command): void {
  const admin = program
    .command("admin")
    .description(
      "Admin operations (requires BRANDNANA_ADMIN_KEY env or ~/.config/brandnana/admin-key)",
    );

  registerHealth(admin);
  registerSpend(admin);
  registerRates(admin);
  registerEvents(admin);
}
