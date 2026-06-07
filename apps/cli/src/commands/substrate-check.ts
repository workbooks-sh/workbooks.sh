// `brandnana substrate check [workdir]` — fail-loud fidelity validator.
//
// The remediation split is GATHER (adaptive, LLM) → RENDER (deterministic).
// `substrate build` (owned by the builder agent in ./substrate.ts) reads the
// GATHER workdir and emits the org faithfully. THIS command is the guard rail:
// it re-reads the rendered org + the source SQLite and asserts that nothing was
// summarised, reused, or fabricated — the exact failure modes seen in the
// Tecovas run-5 harvest (1 product instead of 1358, one logo R2 hash reused for
// every image, invented dates + ad IDs).
//
// Invocation:
//   brandnana substrate check [workdir] [--db <path>] [--run-window-start <iso>]
//
//   workdir defaults to `.` (the brand-<slug>/ directory produced by GATHER).
//   --db defaults to <workdir>/.brandnana/brandnana.sqlite.
//
// Exit-code contract:
//   0  every check PASSED
//   1  one or more checks FAILED, or the workdir/db/org files were unreadable
//
// Designed to be invoked two ways:
//   (a) standalone: `brandnana substrate check brand-tecovas`
//   (b) as a sibling subcommand the builder's ./substrate.ts re-exports
//       (it owns the `substrate` group + `build`; we own `check`).

import { readFileSync, readdirSync, statSync } from "node:fs";
import { resolve } from "node:path";
import Database from "../sqlite.js";
import type { DbLike } from "../sqlite.js";
import type { Command } from "commander";
import { emit, runAction, warn } from "../output.js";

// ── Report model ─────────────────────────────────────────────────────────────

export interface CheckResult {
  /** Short stable id (used by --json consumers). */
  id: string;
  /** Human label. */
  label: string;
  /** true = invariant held. */
  pass: boolean;
  /** One-line outcome (counts, the offending value, etc.). */
  detail: string;
  /** Per-violation lines (capped) shown under a failing check. */
  violations: string[];
}

export interface ValidationReport {
  workdir: string;
  db: string;
  ok: boolean;
  checks: CheckResult[];
  /** Count of failed checks. */
  failed: number;
}

export interface ValidateOptions {
  /** SQLite path; defaults to <workdir>/.brandnana/brandnana.sqlite. */
  db?: string;
  /**
   * ISO-8601 start of the harvest run window. Any org timestamp earlier than
   * this is rejected as a placeholder/fabricated date. If omitted we derive a
   * conservative window start from the youngest source artifact mtime (the
   * SQLite file / the org files themselves) minus a slack margin, so a stale
   * 2024-* literal cannot pass against a 2026 harvest.
   */
  runWindowStart?: string;
  /** ISO-8601 end of the window; defaults to now + 1d slack. */
  runWindowEnd?: string;
  /**
   * Documented product cap. When the crawl was capped (e.g. --max-urls), the
   * org PRODUCT_COUNT legitimately equals the cap, not the brand's full row
   * count. When provided, the count check passes if org count == min(dbCount,
   * cap). Omit for an exact org==db equality assertion.
   */
  productCap?: number;
}

// ── Constants ────────────────────────────────────────────────────────────────

const MAX_VIOLATIONS_SHOWN = 8;
// `needs_mirror` is an honest gap: a singleton media point (logo/screenshot/ad
// creative) was captured but NOT mirrored to R2, so the builder withheld the raw
// vendor URL rather than hotlink it. It is a valid, non-green status.
const VALID_STATUSES = new Set(["ok", "failed", "needs_key", "needs_mirror"]);
// Every mirrored binary must be a real R2 asset URL on the CANONICAL host. This
// MUST reject raw vendor hosts (favicon.svg, media.brand.dev) AND the worker
// default host (*.workers.dev) — only `https://api.brandnana.net/assets/<sha>`
// passes. Keep in lockstep with substrate.ts R2_ASSET_RE.
const R2_ASSET_RE = /^https:\/\/api\.brandnana\.net\/assets\/[0-9a-f]+(?:\.[a-z0-9]+)?$/i;
const HEX_RE = /#[0-9a-fA-F]{6}\b/g;
// A leaf "fact" headline carries the :point: tag. We assert STATUS on each.
const POINT_HEADLINE_RE = /^\*+\s.*:point:/;
// ISO-8601 timestamp at the head of a provenance/event headline or property.
const ISO_TS_RE = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?/;

// ── Small helpers ────────────────────────────────────────────────────────────

function readOrgIfPresent(path: string): string | null {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

function mtimeMs(path: string): number | null {
  try {
    return statSync(path).mtimeMs;
  } catch {
    return null;
  }
}

/** Pull `#+KEY: value` header values from an org file head. */
function orgHeader(text: string, key: string): string | null {
  const re = new RegExp(`^#\\+${key}:\\s*(.+)$`, "im");
  const m = text.match(re);
  return m?.[1]?.trim() ?? null;
}

/** Collect every `:PROP: value` line for a given property name. */
function orgPropertyValues(text: string, prop: string): string[] {
  // [ \t] (NOT \s) so an empty property (e.g. an image-less parent product's
  // `:IMAGES:`) does not bleed across the newline and capture the next line's
  // value (e.g. `:URL:`). Property values are always same-line.
  const re = new RegExp(`^[ \\t]*:${prop}:[ \\t]*(.+)$`, "gim");
  const out: string[] = [];
  for (const m of text.matchAll(re)) {
    const v = m[1]?.trim();
    if (v) out.push(v);
  }
  return out;
}

/** Split an org body into headline blocks (each starts with `*`). */
function headlineBlocks(text: string): string[] {
  const lines = text.split("\n");
  const blocks: string[] = [];
  let cur: string[] = [];
  for (const line of lines) {
    if (/^\*+\s/.test(line)) {
      if (cur.length) blocks.push(cur.join("\n"));
      cur = [line];
    } else if (cur.length) {
      cur.push(line);
    }
  }
  if (cur.length) blocks.push(cur.join("\n"));
  return blocks;
}

function check(id: string, label: string, pass: boolean, detail: string, violations: string[] = []): CheckResult {
  return { id, label, pass, detail, violations: violations.slice(0, MAX_VIOLATIONS_SHOWN) };
}

// ── The checks ───────────────────────────────────────────────────────────────

/**
 * (a) Catalog product count in products.org == SQLite product count
 * (or the documented cap). Reads the canonical truth (SELECT COUNT(*) FROM
 * products WHERE brand_id=?), not crawl.json (which is a summary only).
 */
function checkProductCount(
  productsOrg: string | null,
  db: DbLike | null,
  brandId: string | null,
  cap: number | undefined,
): CheckResult {
  if (!productsOrg) {
    return check(
      "product_count",
      "catalog product count matches SQLite",
      false,
      "catalog/products.org not found",
    );
  }
  if (!db || !brandId) {
    return check(
      "product_count",
      "catalog product count matches SQLite",
      false,
      "SQLite db or brand_id unavailable — cannot verify count",
    );
  }

  const dbCount = (
    db.prepare("SELECT COUNT(*) AS n FROM products WHERE brand_id = ?").get(brandId) as { n: number }
  ).n;

  // Also count the canonical :product:point: headlines as a structural
  // cross-check against the declared header (catches a header that lies).
  const headlineCount = (productsOrg.match(/^\*+\s.*:product:point:/gim) ?? []).length;

  const declared = orgHeader(productsOrg, "PRODUCT_COUNT");
  const declaredN = declared != null ? Number.parseInt(declared, 10) : Number.NaN;

  const expected = cap != null ? Math.min(dbCount, cap) : dbCount;
  const capNote = cap != null ? ` (cap ${cap})` : "";

  const headerOk = declaredN === expected;
  const headlineOk = headlineCount === expected;
  const pass = headerOk && headlineOk;

  const violations: string[] = [];
  if (!headerOk) {
    violations.push(
      `#+PRODUCT_COUNT header = ${Number.isNaN(declaredN) ? "(missing)" : declaredN}, expected ${expected}`,
    );
  }
  if (!headlineOk) {
    violations.push(`:product:point: headlines = ${headlineCount}, expected ${expected}`);
  }

  return check(
    "product_count",
    "catalog product count matches SQLite",
    pass,
    `db=${dbCount}${capNote} header=${Number.isNaN(declaredN) ? "—" : declaredN} headlines=${headlineCount}`,
    violations,
  );
}

/**
 * (b) Every media R2 URL is DISTINCT (no single hash reused across
 * logo/products/ads) and matches https://api.brandnana.net/assets/<sha>.
 * Reads media from the org's IMAGES/MEDIA_URL/PRIMARY_URL/SCREENSHOT_URL
 * properties across all org files in the workdir.
 */
function checkMediaUrls(orgFiles: Array<{ name: string; text: string }>): CheckResult {
  const MEDIA_PROPS = ["IMAGES", "MEDIA_URL", "PRIMARY_URL", "SCREENSHOT_URL"];
  // url -> list of "<file>:<prop>" occurrences (PRODUCT/LOGO media only — see below)
  const seen = new Map<string, string[]>();
  const malformed: string[] = [];
  let total = 0;
  let nonAdTotal = 0;

  for (const { name, text } of orgFiles) {
    // Ad creative reuse is LEGITIMATE: a campaign reuses one hero, and R2 is
    // content-addressed (same creative → same SHA → same URL). So ad media is
    // malformed-checked but EXEMPT from the distinctness/domination check — else
    // "25 ads share the hero" false-flags real data (wb-y9tg). The domination
    // check targets the product/logo "one hash for everything" mirror bug only.
    const isAd = /(^|\/)ads\.org$/.test(name) || name.includes("/ads/");
    for (const prop of MEDIA_PROPS) {
      for (const raw of orgPropertyValues(text, prop)) {
        // IMAGES is comma-joined; the rest are single URLs.
        const urls = raw
          .split(",")
          .map((u) => u.trim())
          .filter(Boolean);
        for (const url of urls) {
          total++;
          if (!R2_ASSET_RE.test(url)) {
            malformed.push(`${name} ${prop}: ${url}`);
            continue;
          }
          if (isAd) continue;
          nonAdTotal++;
          const where = seen.get(url) ?? [];
          where.push(`${name}:${prop}`);
          seen.set(url, where);
        }
      }
    }
  }

  // The failure mode to catch is PATHOLOGICAL reuse — one R2 hash standing in for
  // most/all media (a broken mirror that reused a placeholder/logo for everything,
  // the Tecovas run-5 bug). LIMITED reuse is LEGITIMATE: a brand genuinely shares a
  // lifestyle/hero photo across a few variant products. So flag a URL only when it
  // DOMINATES the media — reused across more than max(3, 30% of all media URLs).
  // (Binary >1 here mis-flagged legit sharing → the brand-scout destructively
  // stripped images from hundreds of products. wb-syjo.)
  const threshold = Math.max(3, Math.floor(nonAdTotal * 0.3));
  const reused: string[] = [];
  for (const [url, where] of seen) {
    if (where.length > threshold) {
      const sha = url.replace(/^.*\/assets\//, "");
      reused.push(`${sha} reused ${where.length}× (> ${threshold}; one hash dominating media)`);
    }
  }

  const violations = [...malformed, ...reused];
  const pass = total > 0 && violations.length === 0;
  const detail =
    total === 0
      ? "no media URLs found in org (expected logo/product/ad images)"
      : `${total} media URLs, ${seen.size} distinct, ${malformed.length} malformed, ${reused.length} over-reused (threshold ${threshold})`;

  return check("media_urls", "media URLs are well-formed R2 assets, no single hash dominating", pass, detail, violations);
}

/**
 * (c) Palette has >=6 distinct hexes. Reads brand.org's palette properties +
 * the Extended palette body lines.
 */
function checkPalette(brandOrg: string | null): CheckResult {
  if (!brandOrg) {
    return check("palette", "palette has ≥6 distinct hexes", false, "brand.org not found");
  }
  const hexes = new Set<string>();
  for (const m of brandOrg.matchAll(HEX_RE)) {
    hexes.add(m[0].toLowerCase());
  }
  const pass = hexes.size >= 6;
  return check(
    "palette",
    "palette has ≥6 distinct hexes",
    pass,
    `${hexes.size} distinct hex colors`,
    pass ? [] : [`found only ${hexes.size}: ${Array.from(hexes).join(", ")}`],
  );
}

/**
 * (d) NO placeholder dates. Every ISO timestamp in every org must fall inside
 * the run window. The window start defaults to (youngest source artifact mtime
 * − slack); a stale 2024-* literal against a 2026 harvest fails loud.
 */
function checkDates(
  orgFiles: Array<{ name: string; text: string }>,
  windowStartMs: number,
  windowEndMs: number,
): CheckResult {
  const startIso = new Date(windowStartMs).toISOString();
  const endIso = new Date(windowEndMs).toISOString();
  const violations: string[] = [];
  let total = 0;
  let nonIsoFlagged = 0;

  // Timestamps live on event headlines and in :GENERATED_AT: / first/last-seen
  // style properties. We scan TS/STATUS-bearing lines: provenance headlines,
  // #+GENERATED_AT, and any property value that looks like a date.
  for (const { name, text } of orgFiles) {
    for (const line of text.split("\n")) {
      // Only consider lines that actually carry a timestamp shape.
      const m = line.match(ISO_TS_RE);
      if (m) {
        total++;
        const t = Date.parse(m[0]);
        if (Number.isNaN(t)) {
          nonIsoFlagged++;
          violations.push(`${name}: unparseable timestamp "${m[0].trim()}"`);
        } else if (t < windowStartMs || t > windowEndMs) {
          violations.push(`${name}: out-of-window "${m[0]}" (line: ${line.trim().slice(0, 80)})`);
        }
        continue;
      }
      // Catch obvious bare-date placeholders (YYYY-MM-DD) outside the window
      // that did NOT match the ISO shape, on date-ish property/headline lines.
      const bare = line.match(/\b(\d{4})-(\d{2})-(\d{2})\b/);
      if (bare && /(:GENERATED_AT:|:FIRST_SEEN|:LAST_SEEN|^\*+\s.*:event:)/i.test(line)) {
        total++;
        const t = Date.parse(`${bare[0]}T00:00:00Z`);
        if (Number.isNaN(t) || t < windowStartMs || t > windowEndMs) {
          violations.push(`${name}: out-of-window date "${bare[0]}" (line: ${line.trim().slice(0, 80)})`);
        }
      }
    }
  }

  const pass = total > 0 && violations.length === 0;
  const detail =
    total === 0
      ? "no timestamps found in org (expected provenance + GENERATED_AT)"
      : `${total} timestamps checked, window [${startIso} .. ${endIso}], ${violations.length} out-of-window${nonIsoFlagged ? `, ${nonIsoFlagged} unparseable` : ""}`;

  return check("dates", "no placeholder dates (all timestamps in run window)", pass, detail, violations);
}

/**
 * (e) Every :point: headline carries a STATUS in {ok,failed,needs_key}.
 */
function checkPointStatus(orgFiles: Array<{ name: string; text: string }>): CheckResult {
  const violations: string[] = [];
  let totalPoints = 0;

  for (const { name, text } of orgFiles) {
    for (const block of headlineBlocks(text)) {
      const head = block.split("\n", 1)[0] ?? "";
      if (!POINT_HEADLINE_RE.test(head)) continue;
      totalPoints++;
      const statusVals = orgPropertyValues(block, "STATUS");
      const status = statusVals[0];
      if (!status) {
        violations.push(`${name}: :point: headline missing STATUS — ${head.trim().slice(0, 70)}`);
      } else if (!VALID_STATUSES.has(status)) {
        violations.push(`${name}: invalid STATUS "${status}" — ${head.trim().slice(0, 60)}`);
      }
    }
  }

  const pass = totalPoints > 0 && violations.length === 0;
  const detail =
    totalPoints === 0
      ? "no :point: headlines found (expected facts across brand/catalog/ads/social/provenance)"
      : `${totalPoints} :point: headlines, ${violations.length} missing/invalid STATUS`;

  return check("point_status", "every :point: headline has a valid STATUS", pass, detail, violations);
}

// ── Workdir → org file collection ────────────────────────────────────────────

const ORG_RELATIVE_PATHS = [
  "brand.org",
  "catalog/products.org",
  "ads.org",
  "harvest-provenance.org",
];

/** Gather all org files in the workdir (the fixed set + any social/*.org). */
function collectOrgFiles(workdir: string): Array<{ name: string; text: string }> {
  const out: Array<{ name: string; text: string }> = [];
  for (const rel of ORG_RELATIVE_PATHS) {
    const text = readOrgIfPresent(resolve(workdir, rel));
    if (text != null) out.push({ name: rel, text });
  }
  // social/<platform>.org — discover via the brand.org social handles is
  // overkill; just glob the social dir.
  try {
    const socialDir = resolve(workdir, "social");
    for (const f of readdirSync(socialDir)) {
      if (f.endsWith(".org")) {
        const text = readOrgIfPresent(resolve(socialDir, f));
        if (text != null) out.push({ name: `social/${f}`, text });
      }
    }
  } catch {
    // no social dir — fine.
  }
  return out;
}

// ── Public API: validateSubstrate ────────────────────────────────────────────

/**
 * Validate a rendered brandnana substrate workdir against its source SQLite.
 * Pure: opens the db read-only-ish (no writes), reads org files, returns a
 * structured report. The caller decides exit code from `report.ok`.
 */
export function validateSubstrate(workdir: string, opts: ValidateOptions = {}): ValidationReport {
  const resolvedWorkdir = resolve(process.cwd(), workdir);
  const dbPath = opts.db
    ? resolve(process.cwd(), opts.db)
    : resolve(resolvedWorkdir, ".brandnana/brandnana.sqlite");

  const orgFiles = collectOrgFiles(resolvedWorkdir);
  const byName = new Map(orgFiles.map((f) => [f.name, f.text]));
  const brandOrg = byName.get("brand.org") ?? null;
  const productsOrg = byName.get("catalog/products.org") ?? null;

  // Open SQLite (the bun:sqlite shim). brand_id is resolved from the DOMAIN in
  // brand.org (or, failing that, the single brand row).
  let db: DbLike | null = null;
  let brandId: string | null = null;
  let dbMtime: number | null = mtimeMs(dbPath);
  try {
    db = new Database(dbPath);
    db.pragma("foreign_keys = ON");
    const domain = brandOrg ? orgHeader(brandOrg, "DOMAIN") : null;
    if (domain) {
      const row = db.prepare("SELECT id FROM brands WHERE domain = ?").get(domain) as
        | { id: string }
        | undefined;
      brandId = row?.id ?? null;
    }
    if (!brandId) {
      const rows = db.prepare("SELECT id FROM brands").all() as Array<{ id: string }>;
      if (rows.length === 1) brandId = rows[0]?.id ?? null;
    }
  } catch (e) {
    warn(`could not open SQLite at ${dbPath}: ${(e as Error).message}`);
    db = null;
  }

  // ── Run window ──
  // End: explicit, else now + 1d slack.
  const windowEndMs = opts.runWindowEnd
    ? Date.parse(opts.runWindowEnd)
    : Date.now() + 24 * 60 * 60 * 1000;
  // Start: explicit (--run-window-start), else a WIDE content window — youngest
  // source-artifact mtime − 10 years. The org carries REAL historical content
  // timestamps (ad created_at, social post dates) that are legitimately months/
  // years old; a tight (run − 2d) window false-flagged them as out-of-window the
  // same way checkMediaUrls false-flagged shared images — risking a destructive
  // agent spiral. 10y still catches the actual targets: epoch placeholders (1970)
  // and far-future/future dates (windowEnd = now + 1d). Pass --run-window-start
  // for a strict provenance-only window. (wb-syjo, sibling of wb-agqd.)
  let windowStartMs: number;
  if (opts.runWindowStart) {
    windowStartMs = Date.parse(opts.runWindowStart);
  } else {
    const mtimes: number[] = [];
    if (dbMtime != null) mtimes.push(dbMtime);
    for (const rel of ["brand.org", "catalog/products.org", "ads.org", "harvest-provenance.org"]) {
      const t = mtimeMs(resolve(resolvedWorkdir, rel));
      if (t != null) mtimes.push(t);
    }
    const youngest = mtimes.length ? Math.max(...mtimes) : Date.now();
    windowStartMs = youngest - 10 * 365 * 24 * 60 * 60 * 1000;
  }

  const checks: CheckResult[] = [
    checkProductCount(productsOrg, db, brandId, opts.productCap),
    checkMediaUrls(orgFiles),
    checkPalette(brandOrg),
    checkDates(orgFiles, windowStartMs, windowEndMs),
    checkPointStatus(orgFiles),
  ];

  if (db) {
    try {
      db.close();
    } catch {
      // ignore
    }
  }

  // If the workdir had no org files at all, that's itself a hard failure.
  if (orgFiles.length === 0) {
    checks.unshift(
      check(
        "workdir",
        "workdir contains rendered org files",
        false,
        `no .org files under ${resolvedWorkdir}`,
      ),
    );
  }

  const failed = checks.filter((c) => !c.pass).length;
  return {
    workdir: resolvedWorkdir,
    db: dbPath,
    ok: failed === 0,
    checks,
    failed,
  };
}

// ── Human-readable rendering ─────────────────────────────────────────────────

export function formatReport(report: ValidationReport): string {
  const lines: string[] = [];
  lines.push(`substrate check: ${report.workdir}`);
  lines.push(`  db: ${report.db}`);
  lines.push("");
  for (const c of report.checks) {
    const mark = c.pass ? "PASS" : "FAIL";
    lines.push(`  [${mark}] ${c.label}`);
    lines.push(`         ${c.detail}`);
    if (!c.pass) {
      for (const v of c.violations) {
        lines.push(`         · ${v}`);
      }
      if (c.violations.length === 0) {
        lines.push("         · (see detail above)");
      }
    }
  }
  lines.push("");
  lines.push(
    report.ok
      ? `RESULT: PASS (${report.checks.length}/${report.checks.length} checks)`
      : `RESULT: FAIL (${report.failed}/${report.checks.length} checks failed)`,
  );
  return lines.join("\n");
}

// ── Command registration ─────────────────────────────────────────────────────

interface CheckOpts {
  db?: string;
  runWindowStart?: string;
  runWindowEnd?: string;
  productCap?: string;
}

/**
 * Attach the `check` verb to a parent `substrate` command. The builder agent's
 * ./substrate.ts (which owns `substrate build`) should call this with its
 * `substrate` Command so `build` and `check` live under one group.
 */
export function attachSubstrateCheck(substrate: Command): void {
  substrate
    .command("check [workdir]")
    .description("Validate a rendered substrate workdir against its source SQLite (fails loud on synthesis)")
    .option("--db <path>", "SQLite path (default <workdir>/.brandnana/brandnana.sqlite)")
    .option("--product-cap <n>", "Documented crawl cap; org count may equal min(dbCount, cap)")
    .option("--run-window-start <iso>", "Reject org timestamps before this ISO-8601 instant")
    .option("--run-window-end <iso>", "Reject org timestamps after this ISO-8601 instant")
    .action((workdir: string | undefined, opts: CheckOpts) =>
      runAction(async () => {
        const report = validateSubstrate(workdir ?? ".", {
          db: opts.db,
          runWindowStart: opts.runWindowStart,
          runWindowEnd: opts.runWindowEnd,
          productCap: opts.productCap != null ? Number.parseInt(opts.productCap, 10) : undefined,
        });
        emit(report, formatReport(report));
        if (!report.ok) {
          // Fail loud: non-zero exit so CI / the harvest pipeline halts.
          process.exit(1);
        }
      }),
    );
}

/**
 * Standalone registration: `brandnana substrate check ...` even before the
 * builder's `substrate build` lands. If ./substrate.ts already created the
 * `substrate` group, this no-ops the group creation (commander reuses an
 * existing named subcommand only if we look it up first).
 */
export function registerSubstrateCheck(program: Command): void {
  const existing = program.commands.find((c) => c.name() === "substrate");
  const substrate =
    existing ?? program.command("substrate").description("Deterministic substrate render & validation");
  attachSubstrateCheck(substrate);
}
