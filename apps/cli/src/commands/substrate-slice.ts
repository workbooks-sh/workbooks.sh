// `brandnana substrate slice [workdir]` — the DETERMINISTIC PRE-READ.
//
// PROBLEM this fixes: the strategist (Stage-2) used to fan out ~5 LLM
// `brand-scout` children, one per slice, each grepping the substrate and writing
// a small report to analysis/reports/<slice>.org. That mechanical fan-out is
// straggler-bound — one slow child gates a barrier the whole run waits on (live
// E2E: ~18min in run #6 vs ~9min solo in run #5). The work is FIXED and purely
// textual (grep/head/jq over the harvested org), so an LLM per slice buys nothing
// but latency + variance.
//
// FIX: this command reproduces, deterministically and in-process, the exact
// per-slice digest the pre-read FALLBACK produced by hand — no LLM, no network,
// no spawn. It reads the harvested Stage-1 substrate at the workdir root and
// writes the SAME five reports/*.org files, in the SAME format, so the
// strategist's downstream AUTHOR step (read analysis/reports/*.org → write
// analysis/*.org) is byte-for-byte unchanged:
//
//   brand.org · ads.org · catalog/products.org · social/*.org · company.json
//        ↓ deterministic slice (this file)
//   analysis/reports/brand.org   · analysis/reports/ads.org
//   analysis/reports/catalog.org · analysis/reports/social.org
//   analysis/reports/reviews.org
//
// Each report is small structured org: one :report: headline + several :finding:
// headlines, each with a :GROUNDS: property listing the REAL Stage-1 :point:
// anchors and a body carrying the real strings (taglines, hooks, prices, handles,
// quoted reviews). It is the SAME contract the children wrote — see
// substrates/brandnana/profile/skills/pre-read.org.
//
// Idempotent: re-running over the same workdir produces the same five files.
// Runs in <1s.

import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import type { Command } from "commander";
import { emit, runAction } from "../output.js";

// ── small text helpers (mirror the FALLBACK's grep/head/sed pipeline) ─────────

function readIf(path: string): string | null {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

/** Concatenate every `social/*.org` (the FALLBACK's `social/*.org` glob). */
function readSocialOrgs(workdir: string): string {
  const dir = join(workdir, "social");
  let names: string[] = [];
  try {
    names = readdirSync(dir).filter((f) => f.endsWith(".org"));
  } catch {
    return "";
  }
  return names
    .map((f) => readIf(join(dir, f)) ?? "")
    .filter(Boolean)
    .join("\n");
}

/**
 * Lines matching `re`, capped at `limit`, each prefixed `   - ` — exactly the
 * FALLBACK's `grep … | head -N | sed 's/^/   - /'`. Returns `[]` (no lines) when
 * nothing matches so the report records an honest gap rather than a stub.
 */
function grepLines(text: string, re: RegExp, limit: number): string[] {
  const out: string[] = [];
  for (const line of text.split("\n")) {
    if (re.test(line)) {
      out.push(`   - ${line.trim()}`);
      if (out.length >= limit) break;
    }
  }
  return out;
}

/**
 * Extract up to `limit` capture-group-0 matches of `re` across `text`, joined by
 * "," with a trailing comma — the FALLBACK's
 * `grep -oE … | head -N | tr '\n' ','` used to build a :GROUNDS: value.
 */
function grepAnchors(text: string, re: RegExp, limit: number): string {
  const found: string[] = [];
  for (const m of text.matchAll(re)) {
    found.push(m[0]);
    if (found.length >= limit) break;
  }
  return found.length ? `${found.join(",")},` : "";
}

// ── per-slice report bodies (1:1 with the FALLBACK heredocs) ──────────────────

interface SliceInput {
  brand: string;
  ads: string;
  catalog: string;
  social: string;
}

/** brand: voice/tone/positioning + palette. */
function reportBrand(brand: string): string {
  const voice = grepLines(brand, /TAGLINE|:brand:|HEADLINE/i, 12);
  const palette = grepLines(brand, /PRIMARY_HEX|SECONDARY_HEX|palette|^\s*-\s.*#/i, 12);
  return [
    "#+TITLE: pre-read report — brand",
    "* brand findings :report:",
    "  :PROPERTIES:",
    "  :SLICE: brand",
    "  :SOURCES: brand.org",
    "  :END:",
    "** voice/tone signals :finding:",
    "   :GROUNDS: brand:tagline, brand:identity",
    "   tagline + headline copy (verbatim) from brand.org:",
    ...(voice.length ? voice : ["   (no tagline/headline lines found)"]),
    "** palette :finding:",
    "   :GROUNDS: brand:palette",
    ...(palette.length ? palette : ["   (no palette swatches found)"]),
    "",
  ].join("\n");
}

/** ads: hooks/copy/CTA + AD_IDs. */
function reportAds(ads: string): string {
  const grounds = grepAnchors(ads, /:AD_ID:[^ ]*/g, 8);
  const hooks = grepLines(ads, /:HOOK:|:CTA:|:MOOD:|:AD_ID:/, 40);
  return [
    "#+TITLE: pre-read report — ads",
    "* ads findings :report:",
    "  :PROPERTIES:",
    "  :SLICE: ads",
    "  :SOURCES: ads.org",
    "  :END:",
    "** messaging hooks + the ad ids that carry them :finding:",
    `   :GROUNDS: ${grounds}`,
    ...(hooks.length ? hooks : ["   (no ad hooks/ids found)"]),
    "",
  ].join("\n");
}

/** catalog: what they sell + price bands. */
function reportCatalog(catalog: string): string {
  const grounds = grepAnchors(catalog, /:product:point:[^ ]*/g, 8);
  const mix = grepLines(catalog, /#\+PRODUCT_COUNT|:PRICE:|:CATEGORY:|:product:point:/, 40);
  return [
    "#+TITLE: pre-read report — catalog",
    "* catalog findings :report:",
    "  :PROPERTIES:",
    "  :SLICE: catalog",
    "  :SOURCES: catalog/products.org",
    "  :END:",
    "** product mix + price bands :finding:",
    `   :GROUNDS: ${grounds}`,
    ...(mix.length ? mix : ["   (no products found)"]),
    "",
  ].join("\n");
}

/** social: audience + follower scale. */
function reportSocial(social: string): string {
  const grounds = grepAnchors(social, /:HANDLE:[^ ]*/g, 8);
  const reach = grepLines(social, /:FOLLOWERS:|:HANDLE:|:VERIFIED:|:URL:/, 30);
  return [
    "#+TITLE: pre-read report — social",
    "* social findings :report:",
    "  :PROPERTIES:",
    "  :SLICE: social",
    "  :SOURCES: social/*.org",
    "  :END:",
    "** audience + reach :finding:",
    `   :GROUNDS: ${grounds}`,
    ...(reach.length ? reach : ["   (no social handles found)"]),
    "",
  ].join("\n");
}

/** reviews: real testimonials wherever they live (ads + social + catalog). */
function reportReviews(input: SliceInput): string {
  const corpus = [input.ads, input.social, input.catalog].join("\n");
  const quotes = grepLines(corpus, /review|testimonial|comment|"/i, 30);
  return [
    "#+TITLE: pre-read report — reviews",
    "* reviews findings :report:",
    "  :PROPERTIES:",
    "  :SLICE: reviews",
    "  :SOURCES: ads.org social/*.org catalog/products.org",
    "  :END:",
    "** quoted social proof :finding:",
    "   :GROUNDS: (cite the point each quote came from)",
    ...(quotes.length ? quotes : ["   (no quoted reviews/comments found)"]),
    "",
  ].join("\n");
}

// ── public API ────────────────────────────────────────────────────────────────

export interface SliceResult {
  workdir: string;
  reportsDir: string;
  files: string[];
}

/**
 * Read the harvested substrate at `workdir` and write the five pre-read reports
 * under `<workdir>/analysis/reports/`. Pure deterministic text transform.
 */
export function sliceSubstrate(workdir: string): SliceResult {
  const resolvedWorkdir = resolve(process.cwd(), workdir);
  const reportsDir = join(resolvedWorkdir, "analysis", "reports");
  mkdirSync(reportsDir, { recursive: true });

  const input: SliceInput = {
    brand: readIf(join(resolvedWorkdir, "brand.org")) ?? "",
    ads: readIf(join(resolvedWorkdir, "ads.org")) ?? "",
    catalog: readIf(join(resolvedWorkdir, "catalog", "products.org")) ?? "",
    social: readSocialOrgs(resolvedWorkdir),
  };

  const reports: Array<[string, string]> = [
    ["brand.org", reportBrand(input.brand)],
    ["ads.org", reportAds(input.ads)],
    ["catalog.org", reportCatalog(input.catalog)],
    ["social.org", reportSocial(input.social)],
    ["reviews.org", reportReviews(input)],
  ];

  const files: string[] = [];
  for (const [name, body] of reports) {
    const target = join(reportsDir, name);
    writeFileSync(target, `${body}\n`);
    files.push(target);
  }

  return { workdir: resolvedWorkdir, reportsDir, files };
}

// ── command registration ──────────────────────────────────────────────────────

/**
 * Attach the `slice` verb to an existing `substrate` group (reused when present,
 * created otherwise — same pattern as registerSubstrateCheck).
 */
export function registerSubstrateSlice(program: Command): void {
  const existing = program.commands.find((c) => c.name() === "substrate");
  const substrate =
    existing ?? program.command("substrate").description("Deterministic substrate render & validation");

  substrate
    .command("slice [workdir]")
    .description(
      "Deterministic pre-read: digest the harvested substrate into analysis/reports/*.org (no LLM, no spawn, no network)",
    )
    .option("--workdir <dir>", "Brand workdir root (overrides the positional arg / cwd)")
    .action((workdirArg: string | undefined, opts: { workdir?: string }) =>
      runAction(async () => {
        const workdir = opts.workdir ?? workdirArg ?? ".";
        const resolvedWorkdir = resolve(process.cwd(), workdir);
        if (!existsSync(join(resolvedWorkdir, "brand.org"))) {
          throw new Error(
            `no brand.org at ${resolvedWorkdir} — is this a built substrate workdir? (run substrate build first)`,
          );
        }
        const result = sliceSubstrate(workdir);
        emit(
          result,
          [
            `pre-read sliced → ${result.reportsDir}`,
            ...result.files.map((f) => `  ${f.replace(`${result.reportsDir}/`, "  ")}`),
          ].join("\n"),
        );
      }),
    );
}
