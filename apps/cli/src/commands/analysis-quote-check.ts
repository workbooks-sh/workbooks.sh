// §3.2 testimonial quote byte-provenance (wb-syjo / wb-on95).
//
// The analysis gate already proves a testimonial CITES a real Stage-1 point. It
// did NOT prove the QUOTED text is real — a synthesized testimonial with an
// invented quote (the cardinal sin per write-analysis.org) passed. This check
// asserts every quoted string in a `testimonials` insight actually appears in
// the Stage-1 substrate.
//
// v1 is COARSE on purpose: the quote must appear SOMEWHERE in the substrate (not
// necessarily the specific cited point). That catches invention — the real
// failure mode — cheaply. Per-cited-point precision is a refinement (would need
// anchor→point-body retention; see wb-on95).

import type { AnalysisCheckResult, ParsedInsight } from "./analysis-check.js";

const MAX_VIOLATIONS_SHOWN = 8;
// Quotes shorter than this are too generic to verify (e.g. "love it") — skip,
// to avoid both false alarms and trivial matches.
const MIN_QUOTE_LEN = 12;

// Normalise text for substring matching: unify smart quotes, lowercase, collapse
// whitespace. Applied identically to the haystack and each quote.
function normalize(s: string): string {
  return s
    .replace(/[‘’‚‛]/g, "'")
    .replace(/[“”„‟]/g, '"')
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Extract quoted substrings from prose. Matches straight and smart DOUBLE
 * quotes (single quotes are skipped — too easily confused with apostrophes).
 * Returns the inner text of each quote, trimmed.
 */
export function extractQuotes(text: string): string[] {
  const out: string[] = [];
  for (const m of text.matchAll(/[“"]([^“”"]{1,400})[”"]/g)) {
    const inner = (m[1] ?? "").trim();
    if (inner.length > 0) out.push(inner);
  }
  return out;
}

/**
 * Assert every verifiable quote in each `testimonials` insight appears in the
 * Stage-1 substrate. Non-testimonial insights are ignored (only testimonials
 * make the "real customer said X" claim).
 */
export function checkQuoteGrounding(
  insights: ParsedInsight[],
  substrateOrg: Array<{ name: string; text: string }>,
): AnalysisCheckResult {
  const haystack = normalize(substrateOrg.map((f) => f.text).join("\n"));
  const violations: string[] = [];
  let quotesChecked = 0;

  for (const ins of insights) {
    if (ins.type !== "testimonials") continue;
    for (const quote of extractQuotes(ins.body)) {
      const norm = normalize(quote);
      if (norm.length < MIN_QUOTE_LEN) continue;
      quotesChecked++;
      if (!haystack.includes(norm)) {
        violations.push(`${ins.file}: quote not found in harvested data (org/raw/SQLite) — "${quote.slice(0, 60)}"`);
      }
    }
  }

  const pass = violations.length === 0;
  const detail = pass
    ? `${quotesChecked} testimonial quote(s) verified against harvested data`
    : `${violations.length} of ${quotesChecked} testimonial quote(s) not found in harvested data`;
  return {
    id: "quote_grounding",
    label: "every testimonial quote appears in the harvested substrate",
    pass,
    detail,
    violations: violations.slice(0, MAX_VIOLATIONS_SHOWN),
  };
}
