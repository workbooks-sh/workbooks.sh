// `brandnana analysis check [workdir]` — fail-loud Stage-2 grounding validator.
//
// The brandnana pipeline splits GATHER (Stage-1, adaptive LLM) → RENDER (Stage-1,
// deterministic `substrate build`) → ANALYZE (Stage-2, the strategist). Stage-1
// produces a faithful, queryable org substrate (brand.org, catalog/products.org,
// social/*.org, ads.org, harvest-provenance.org) whose every fact is a `:point:`
// headline. Stage-2's job is to REASON over that substrate and emit an *analysis*
// layer — analysis/*.org files of `:insight:` headlines (voice, tone, audience,
// positioning, whitespace, testimonials, messaging-pillars, copy-ideas, ad-ideas,
// archetype, dos-donts) — each grounded in the Stage-1 points it analyzed.
//
// THIS command is the guard rail for that layer, the analogue of `substrate
// check` one level up. Where `substrate check` rejects a render that summarised /
// reused / fabricated the GATHER, `analysis check` rejects an analysis that
// FABRICATED its conclusions: every `:insight:` MUST carry a non-empty `:GROUNDS:`
// property citing `:point:` ids that ACTUALLY EXIST in the Stage-1 substrate. An
// insight with no grounds, or with a dangling citation, or a substrate that is
// missing whole categories of insight, fails loud (non-zero exit) so the
// strategist cannot finish (DONE) on hand-waved strategy.
//
// Invocation:
//   brandnana analysis check [workdir]
//
//   workdir defaults to `.` (the brand-<slug>/ directory). The Stage-1 org lives
//   at the workdir root (brand.org, ads.org, …, social/*.org); the Stage-2
//   analysis lives under <workdir>/analysis/*.org.
//
// Exit-code contract:
//   0  every check PASSED
//   1  one or more checks FAILED, or the analysis/substrate org was unreadable
//
// Modelled on ./substrate-check.ts — it reuses that file's org-parsing approach
// (header/property/headline-block helpers) so the two validators stay in lockstep.

import { readFileSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import type { Command } from "commander";
import { emit, runAction } from "../output.js";
import Database from "../sqlite.js";
import type { DbLike } from "../sqlite.js";
import { checkQuoteGrounding } from "./analysis-quote-check.js";

// ── Report model (kept structurally identical to substrate-check's) ───────────

export interface AnalysisCheckResult {
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

export interface AnalysisReport {
  workdir: string;
  analysisDir: string;
  ok: boolean;
  checks: AnalysisCheckResult[];
  /** Count of failed checks. */
  failed: number;
  /** The set of insight types present (for the coverage line). */
  typesPresent: string[];
}

// ── Constants ────────────────────────────────────────────────────────────────

const MAX_VIOLATIONS_SHOWN = 8;

// A Stage-2 fact headline carries the `:insight:` tag. Each MUST cite GROUNDS.
const INSIGHT_HEADLINE_RE = /^\*+\s.*:insight:/;
// A Stage-1 fact headline carries the `:point:` tag — the only thing GROUNDS may
// cite. Kept in lockstep with substrate-check.ts POINT_HEADLINE_RE.
const POINT_HEADLINE_RE = /^\*+\s.*:point:/;

// The core insight types the analysis substrate MUST cover for the gate to pass.
// These are the queryable strategy primitives the book/deck and the agent
// book-query path read back ("what is their voice / best testimonials / copy
// ideas"). The strategist tags each `:insight:` with one of these as a leading
// tag (e.g. `:insight:voice:`), and also stamps a :TYPE: property as the
// machine-stable key. Missing a required type = an incomplete analysis.
const REQUIRED_INSIGHT_TYPES = [
  "voice",
  "tone",
  "audience",
  "positioning",
  "messaging-pillars",
  "copy-ideas",
  "ad-ideas",
] as const;
// Recognised (but not all-required) types — the full Stage-2 vocabulary. An
// insight whose :TYPE: is outside this set is flagged as an unknown type so the
// OQL gates ("(and (tags insight) (property TYPE testimonials))") keep matching.
const KNOWN_INSIGHT_TYPES = new Set<string>([
  ...REQUIRED_INSIGHT_TYPES,
  "personas",
  "whitespace",
  "testimonials",
  "archetype",
  "dos-donts",
]);

// ── Small helpers (mirrored from substrate-check.ts) ─────────────────────────

function readOrgIfPresent(path: string): string | null {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return null;
  }
}

/** Collect every `:PROP: value` line for a given property name within a block. */
function orgPropertyValues(text: string, prop: string): string[] {
  // [ \t] (NOT \s) so an empty property does not bleed across the newline and
  // capture the next line's value. Property values are always same-line.
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

/** Every tag in a headline's trailing `:a:b:c:` run, lower-cased. */
function allHeadlineTags(headline: string): string[] {
  const m = headline.match(/:([a-z0-9:_-]+):\s*$/i);
  if (!m?.[1]) return [];
  return m[1].split(":").filter(Boolean).map((t) => t.toLowerCase());
}

// Tags that are structural markers, not semantic anchors.
const STRUCTURAL_TAGS = new Set(["point", "insight", "visual", "index"]);

/** The leading non-structural tag after a known marker, e.g.
 *  `:insight:voice:` → "voice". Used as a fallback type when :TYPE: is absent. */
function leadingTypeTag(headline: string, marker: string): string | null {
  for (const t of allHeadlineTags(headline)) {
    if (t === marker || STRUCTURAL_TAGS.has(t)) continue;
    return t;
  }
  return null;
}

function check(
  id: string,
  label: string,
  pass: boolean,
  detail: string,
  violations: string[] = [],
): AnalysisCheckResult {
  return { id, label, pass, detail, violations: violations.slice(0, MAX_VIOLATIONS_SHOWN) };
}

// ── Stage-1 anchor extraction: what GROUNDS may legitimately cite ────────────

// The properties whose VALUES are themselves citable anchors (an ID-bearing
// point can be grounded by its id). Every OTHER property on a point is a *data*
// property — NOT an anchor — and the commonest strategist mistake is to cite
// `<stem>:<property>` (e.g. `brand:tagline`) as if a property were a tag-anchor.
const ID_PROPS = ["ID", "AD_ID", "HANDLE", "POINT"];

/**
 * Rich view of the citable Stage-1 surface. Beyond the flat `anchors` set used
 * for the pass/fail test, we keep enough structure to explain WHY a citation
 * failed and to suggest the nearest valid form:
 *
 *   - `anchors`        — every resolvable anchor (the membership test).
 *   - `stems`          — file stems present (`brand`, `ads`, `catalog`, …):
 *                        each is a valid *coarse* anchor on its own.
 *   - `tagsByStem`     — for each stem, the non-structural tags seen on its
 *                        points → the `<stem>:<tag>` tag-anchors that resolve.
 *   - `propsByStem`    — for each stem, the PROPERTY NAMES seen on its points
 *                        (lower-cased), e.g. brand → {tagline, domain, …}. Used
 *                        to catch "that's a property, not a tag-anchor".
 *   - `idsByStem`      — for each stem, the id-prop VALUES (ID/AD_ID/HANDLE/
 *                        POINT) of its points — the precise per-point anchors,
 *                        for "did you mean :ID: 'tecovas'".
 *
 * An anchor is any value that uniquely identifies a `:point:` headline so a
 * Stage-2 insight can ground a claim in it:
 *
 *   - the `:ID:` property of a `:point:` headline (brand slug, product slug)
 *   - the `:AD_ID:` of an `:ad:point:` headline
 *   - the `:HANDLE:` of a `:social:point:` headline
 *   - the `:POINT:` of a provenance `:event:point:` headline
 *   - a tag-anchor `<file-stem>:<leading-tag>` for `:point:`s with no ID prop
 *     (palette / fonts / logo / screenshot), e.g. `brand:palette`, `brand:fonts`
 *   - the bare `<file-stem>` as a coarse whole-section anchor (`ads`, `social`)
 *
 * GROUNDS citations are matched case-insensitively against `anchors`.
 */
interface SubstrateAnchors {
  anchors: Set<string>;
  pointCount: number;
  stems: Set<string>;
  tagsByStem: Map<string, Set<string>>;
  propsByStem: Map<string, Set<string>>;
  idsByStem: Map<string, Set<string>>;
}

function collectSubstrateAnchors(orgFiles: Array<{ name: string; text: string }>): SubstrateAnchors {
  const anchors = new Set<string>();
  const stems = new Set<string>();
  const tagsByStem = new Map<string, Set<string>>();
  const propsByStem = new Map<string, Set<string>>();
  const idsByStem = new Map<string, Set<string>>();
  let pointCount = 0;

  const bucket = (m: Map<string, Set<string>>, k: string): Set<string> => {
    let s = m.get(k);
    if (!s) {
      s = new Set<string>();
      m.set(k, s);
    }
    return s;
  };

  for (const { name, text } of orgFiles) {
    // file stem without extension/dir, e.g. "social/tiktok.org" → "tiktok"
    const stem = name.replace(/^.*\//, "").replace(/\.org$/i, "").toLowerCase();
    stems.add(stem);
    for (const block of headlineBlocks(text)) {
      const head = block.split("\n", 1)[0] ?? "";
      if (!POINT_HEADLINE_RE.test(head)) continue;
      pointCount++;

      for (const prop of ID_PROPS) {
        for (const v of orgPropertyValues(block, prop)) {
          anchors.add(v.toLowerCase());
          bucket(idsByStem, stem).add(v.toLowerCase());
        }
      }

      // Record EVERY property name present on this point (lower-cased) so we can
      // recognise `<stem>:<property>` mis-citations and name the property.
      for (const m of block.matchAll(/^[ \t]*:([A-Za-z][A-Za-z0-9_]*):[ \t]/gm)) {
        const p = m[1]?.toLowerCase();
        if (p && p !== "properties" && p !== "end") bucket(propsByStem, stem).add(p);
      }

      // Tag-anchors: <stem>:<tag> for EVERY non-structural tag on the headline,
      // so a palette/fonts/logo point (no :ID:) is citable, and an ID'd point can
      // ALSO be cited by its semantic location. e.g. `:ad:google:point:` in
      // ads.org yields BOTH `ads:ad` and `ads:google`; `:social:tiktok:point:`
      // in social/tiktok.org yields `tiktok:social` and `tiktok:tiktok`.
      for (const tag of allHeadlineTags(head)) {
        if (STRUCTURAL_TAGS.has(tag)) continue;
        anchors.add(`${stem}:${tag}`);
        bucket(tagsByStem, stem).add(tag);
      }
      // The bare file stem is also a valid coarse anchor ("social", "ads",
      // "catalog") so a cross-cutting insight can ground in a whole section.
      anchors.add(stem);
    }
    // Whole-file coarse anchor regardless of whether it had points.
    anchors.add(stem);
  }

  return { anchors, pointCount, stems, tagsByStem, propsByStem, idsByStem };
}

// ── Diagnosing an unresolvable citation ──────────────────────────────────────

/** Levenshtein edit distance — small, no deps, for "did you mean" ranking. */
function editDistance(a: string, b: string): number {
  const m = a.length;
  const n = b.length;
  if (m === 0) return n;
  if (n === 0) return m;
  let prev: number[] = Array.from({ length: n + 1 }, (_, j) => j);
  let cur: number[] = new Array<number>(n + 1).fill(0);
  for (let i = 1; i <= m; i++) {
    cur[0] = i;
    for (let j = 1; j <= n; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      const del = (prev[j] ?? 0) + 1;
      const ins = (cur[j - 1] ?? 0) + 1;
      const sub = (prev[j - 1] ?? 0) + cost;
      cur[j] = Math.min(ins, del, sub);
    }
    [prev, cur] = [cur, prev];
  }
  return prev[n] ?? n;
}

/** The k anchors closest to `cite` by edit distance (ties broken alphabetically). */
function nearestAnchors(cite: string, anchors: Set<string>, k = 3): string[] {
  return [...anchors]
    .map((a) => ({ a, d: editDistance(cite, a) }))
    // Only suggest genuinely-near candidates (within ~40% of length, min 3).
    .filter(({ d }) => d <= Math.max(3, Math.ceil(cite.length * 0.45)))
    .sort((x, y) => x.d - y.d || x.a.localeCompare(y.a))
    .slice(0, k)
    .map(({ a }) => a);
}

/**
 * Explain, in one actionable line, why `cite` did not resolve and what the
 * agent should have written instead. The returned string ALWAYS ends with the
 * valid forms available for the intended target so the strategist can fix the
 * GROUNDS without reverse-engineering the anchor grammar.
 */
function diagnoseDangling(cite: string, sub: SubstrateAnchors): string {
  // A citation is structured as <head><sep><tail> where sep is ':' or '.'.
  const sep = cite.match(/[:.]/)?.[0];
  const head = sep ? cite.slice(0, cite.indexOf(sep)) : cite;
  const tail = sep ? cite.slice(cite.indexOf(sep) + 1) : "";

  // Is the head a real file-stem / section that DOES resolve coarsely?
  const headResolves = sub.stems.has(head) || sub.anchors.has(head);

  // Helper: list the concrete valid forms for a target stem.
  const formsFor = (stem: string): string => {
    const parts: string[] = [`'${stem}'`];
    const ids = [...(sub.idsByStem.get(stem) ?? [])].sort();
    if (ids.length) {
      const shown = ids.slice(0, 4).map((i) => `'${i}'`).join(", ");
      parts.push(`:ID: ${shown}${ids.length > 4 ? ", …" : ""}`);
    }
    const tags = [...(sub.tagsByStem.get(stem) ?? [])].sort();
    if (tags.length) {
      const shown = tags.slice(0, 6).map((t) => `'${stem}:${t}'`).join(", ");
      parts.push(`tag-anchors ${shown}${tags.length > 6 ? ", …" : ""}`);
    }
    return parts.join("; ");
  };

  if (headResolves && tail) {
    const props = sub.propsByStem.get(head) ?? new Set<string>();
    const tags = sub.tagsByStem.get(head) ?? new Set<string>();
    // The classic mistake: cited `<stem>:<property>` — the tail names a PROPERTY
    // on that point, not a tag. Tell the agent exactly that, and the real forms.
    if (props.has(tail) && !tags.has(tail)) {
      return (
        `unresolved; '${head}' resolves but ':${tail.toUpperCase()}:' is a PROPERTY of that point, ` +
        `not a tag-anchor. The ${head} point resolves as ${formsFor(head)}. ` +
        `Did you mean '${head}'?`
      );
    }
    // Head resolves but the tail isn't a known tag → suggest the real tag-anchors.
    return (
      `unresolved; '${head}' resolves but ':${tail}:' is not a tag-anchor on the ${head} point. ` +
      `The ${head} point resolves as ${formsFor(head)}. Did you mean '${head}'?`
    );
  }

  // Head doesn't resolve at all. If they used a '.' separator (e.g.
  // `identity.brand`) it may be a provenance :POINT: id, or a fabricated path.
  const near = nearestAnchors(cite, sub.anchors);
  const stemList = [...sub.stems].sort().map((s) => `'${s}'`).join(", ");
  if (near.length) {
    return (
      `unresolved — no Stage-1 :point: carries this anchor. ` +
      `Nearest resolvable: ${near.map((n) => `'${n}'`).join(", ")}. ` +
      `Valid coarse anchors (file stems): ${stemList}.`
    );
  }
  return (
    `unresolved — no Stage-1 :point: carries this anchor, and nothing close exists. ` +
    `Valid forms are :ID:/:AD_ID:/:HANDLE:/:POINT: values, '<stem>:<tag>' tag-anchors, ` +
    `or a bare file-stem. Available stems: ${stemList}.`
  );
}

/** Parse a GROUNDS property value into the individual point-id citations.
 *  Accepts comma- or whitespace-separated ids, and tolerates org link syntax
 *  `[[id:the-cartwright]]` (extracting `the-cartwright`). */
function parseGrounds(raw: string): string[] {
  return raw
    .split(/[,\s]+/)
    .map((g) => g.trim())
    .map((g) => {
      const link = g.match(/\[\[id:([^\]]+)\]\]/i);
      return (link?.[1] ?? g).replace(/^id:/i, "").toLowerCase();
    })
    .filter(Boolean);
}

// ── Insight extraction from the Stage-2 analysis org ─────────────────────────

export interface ParsedInsight {
  file: string;
  headline: string;
  type: string | null;
  grounds: string[];
  /** raw GROUNDS property value(s), for diagnostics. */
  groundsRaw: string;
  /** the insight's prose body (lines joined with spaces) — for quote-provenance. */
  body: string;
  bodyLen: number;
}

function collectInsights(analysisFiles: Array<{ name: string; text: string }>): ParsedInsight[] {
  const out: ParsedInsight[] = [];
  for (const { name, text } of analysisFiles) {
    for (const block of headlineBlocks(text)) {
      const head = block.split("\n", 1)[0] ?? "";
      if (!INSIGHT_HEADLINE_RE.test(head)) continue;
      const typeProp = orgPropertyValues(block, "TYPE")[0]?.toLowerCase() ?? null;
      const type = typeProp ?? leadingTypeTag(head, "insight");
      const groundsRaw = orgPropertyValues(block, "GROUNDS").join(", ");
      const grounds = groundsRaw ? parseGrounds(groundsRaw) : [];
      // body = block minus the headline + the :PROPERTIES: drawer.
      const bodyLines = block
        .split("\n")
        .slice(1)
        .filter((l) => !/^[ \t]*:[A-Z_]+:/.test(l) && !/^[ \t]*:(PROPERTIES|END):/i.test(l));
      const body = bodyLines.join(" ").trim();
      // bodyLen keeps its prior semantics (join "") so the substance gate is unchanged.
      const bodyLen = bodyLines.join("").trim().length;
      out.push({ file: name, headline: head.trim(), type, grounds, groundsRaw, body, bodyLen });
    }
  }
  return out;
}

// ── The checks ───────────────────────────────────────────────────────────────

/** (a) Every `:insight:` has a NON-EMPTY `:GROUNDS:`. No grounds = fabricated. */
function checkGroundsPresent(insights: ParsedInsight[]): AnalysisCheckResult {
  const violations: string[] = [];
  for (const ins of insights) {
    if (ins.grounds.length === 0) {
      violations.push(`${ins.file}: ungrounded insight — ${ins.headline.slice(0, 70)}`);
    }
  }
  const pass = insights.length > 0 && violations.length === 0;
  const detail =
    insights.length === 0
      ? "no :insight: headlines found under analysis/ (expected the Stage-2 analysis layer)"
      : `${insights.length} insights, ${violations.length} with no GROUNDS`;
  return check("grounds_present", "every :insight: carries a non-empty :GROUNDS:", pass, detail, violations);
}

/**
 * (b) Every GROUNDS citation resolves to a REAL Stage-1 `:point:` anchor.
 * A dangling citation (a point id that does not exist in the substrate) is the
 * Stage-2 analogue of an invented ad id — it means the insight was grounded in
 * a fact that isn't there. Reject it.
 */
function checkGroundsResolve(
  insights: ParsedInsight[],
  sub: SubstrateAnchors,
): AnalysisCheckResult {
  const anchors = sub.anchors;
  const violations: string[] = [];
  let totalCitations = 0;
  let dangling = 0;
  for (const ins of insights) {
    for (const g of ins.grounds) {
      totalCitations++;
      if (!anchors.has(g)) {
        dangling++;
        // ACTIONABLE: don't just say "dangling X" — explain WHY it didn't
        // resolve and LIST the valid anchors for the intended target so the
        // strategist can fix the GROUNDS in one pass instead of probing forms.
        violations.push(
          `${ins.file}: citation '${g}' ${diagnoseDangling(g, sub)} ` +
            `(in: ${ins.headline.slice(0, 48)})`,
        );
      }
    }
  }
  // Pass only if there are citations AND none dangle. (The grounds_present check
  // already fails the no-citations case; here we additionally require the
  // substrate anchor set to be non-empty so we don't vacuously pass.)
  const pass = totalCitations > 0 && anchors.size > 0 && dangling === 0;
  const detail =
    anchors.size === 0
      ? "no Stage-1 :point: anchors found — substrate org missing or empty (cannot verify grounding)"
      : `${totalCitations} citations across ${insights.length} insights, ${anchors.size} substrate anchors, ${dangling} dangling`;
  return check(
    "grounds_resolve",
    "every :GROUNDS: citation resolves to a real Stage-1 :point:",
    pass,
    detail,
    violations,
  );
}

/**
 * (c) Coverage: the analysis spans the REQUIRED insight types. A book that has
 * voice but no positioning, or copy-ideas but no audience, is incomplete — the
 * downstream deck/agent query path expects all of them present.
 */
function checkCoverage(insights: ParsedInsight[]): { result: AnalysisCheckResult; typesPresent: string[] } {
  const present = new Set<string>();
  const unknown: string[] = [];
  for (const ins of insights) {
    if (!ins.type) continue;
    present.add(ins.type);
    if (!KNOWN_INSIGHT_TYPES.has(ins.type)) unknown.push(ins.type);
  }
  const missing = REQUIRED_INSIGHT_TYPES.filter((t) => !present.has(t));
  const violations: string[] = [];
  for (const m of missing) violations.push(`missing required insight type: ${m}`);
  for (const u of [...new Set(unknown)]) violations.push(`unknown insight TYPE "${u}" (not in the Stage-2 vocabulary)`);
  const pass = missing.length === 0 && unknown.length === 0 && insights.length > 0;
  const detail =
    insights.length === 0
      ? "no insights to cover"
      : `${present.size} types present [${[...present].sort().join(", ")}], ${missing.length} required missing`;
  return {
    result: check("coverage", "analysis covers the required insight types", pass, detail, violations),
    typesPresent: [...present].sort(),
  };
}

/**
 * (d) Substance: an insight must say something — a headline + GROUNDS with an
 * empty body is a citation with no analysis. Require a non-trivial body so the
 * strategist can't ship a skeleton that merely points at the data.
 */
function checkSubstance(insights: ParsedInsight[]): AnalysisCheckResult {
  const MIN_BODY = 40; // chars of real prose under the headline/drawer.
  const violations: string[] = [];
  for (const ins of insights) {
    if (ins.bodyLen < MIN_BODY) {
      violations.push(
        `${ins.file}: thin insight (${ins.bodyLen} chars body, need ≥${MIN_BODY}) — ${ins.headline.slice(0, 50)}`,
      );
    }
  }
  const pass = insights.length > 0 && violations.length === 0;
  const detail =
    insights.length === 0
      ? "no insights to weigh"
      : `${insights.length} insights, ${violations.length} thinner than ${MIN_BODY} chars`;
  return check("substance", "every :insight: has a non-trivial analysis body", pass, detail, violations);
}

// Normalise a headline for similarity comparison: drop leading stars, the
// trailing :tag:tag: run, lowercase, collapse whitespace.
function normalizeHeadline(headline: string): string {
  return headline
    .replace(/^\*+\s*/, "")
    .replace(/\s+:[\w:@-]+:\s*$/, "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Quality floor (§3.1): the strategist must not ship two near-identical insights
 * of the SAME type — a duplicate argument wastes a slide and reads as padding.
 * Conservative: only flags pairs whose normalised headlines are ≥85% similar
 * (normalised edit distance ≤ 0.15), so genuinely-distinct insights that merely
 * share words don't trip it.
 */
export function checkDuplicateInsights(insights: ParsedInsight[]): AnalysisCheckResult {
  const SIM_THRESHOLD = 0.15; // max normalised edit distance to count as dup
  const violations: string[] = [];
  const byType = new Map<string, ParsedInsight[]>();
  for (const ins of insights) {
    const key = ins.type ?? "(untyped)";
    const arr = byType.get(key) ?? [];
    arr.push(ins);
    byType.set(key, arr);
  }

  for (const [type, group] of byType) {
    for (let i = 0; i < group.length; i++) {
      for (let j = i + 1; j < group.length; j++) {
        const a = normalizeHeadline(group[i]?.headline ?? "");
        const b = normalizeHeadline(group[j]?.headline ?? "");
        if (a.length === 0 || b.length === 0) continue;
        const norm = editDistance(a, b) / Math.max(a.length, b.length);
        if (norm <= SIM_THRESHOLD) {
          violations.push(`${type}: near-duplicate insights — "${a.slice(0, 40)}" ≈ "${b.slice(0, 40)}"`);
        }
      }
    }
  }

  const pass = violations.length === 0;
  const detail = pass
    ? `${insights.length} insights, no near-duplicates`
    : `${violations.length} near-duplicate insight pair(s)`;
  return check("no_duplicates", "no two same-type insights are near-identical", pass, detail, violations);
}

// ── Workdir → org file collection ────────────────────────────────────────────

// The Stage-1 substrate org files (the citable layer) at the workdir root.
const SUBSTRATE_RELATIVE_PATHS = [
  "brand.org",
  "catalog/products.org",
  "ads.org",
  "harvest-provenance.org",
];

/** Gather the Stage-1 substrate org (root files + social/*.org). */
function collectSubstrateOrg(workdir: string): Array<{ name: string; text: string }> {
  const out: Array<{ name: string; text: string }> = [];
  for (const rel of SUBSTRATE_RELATIVE_PATHS) {
    const text = readOrgIfPresent(resolve(workdir, rel));
    if (text != null) out.push({ name: rel, text });
  }
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

/**
 * Gather HARVESTED-but-not-org'd text the quote-check must also see: raw/*.json
 * (e.g. TikTok-Shop reviews fetched by `social reviews`) and the SQLite free-text
 * columns that `substrate build` does NOT emit verbatim (products.description /
 * raw_json, ads.body / raw_json, brands.descriptors_json). The .org render is a
 * LOSSY projection of these, so a quote legitimately harvested into raw/ or
 * SQLite is invisible to the .org-only haystack → false flag. This widens ONLY
 * the quote-grounding haystack; it stays out of collectSubstrateOrg so the
 * anchor/`substrate_present`/grounds-resolve checks remain org-only. The
 * provenance guarantee is preserved: a quote must still appear in HARVESTED data,
 * just not restricted to the org layer. (wb-on95 / wb-5vs5.)
 */
function collectHarvestHaystack(workdir: string): Array<{ name: string; text: string }> {
  const out: Array<{ name: string; text: string }> = [];
  try {
    const rawDir = resolve(workdir, "raw");
    for (const f of readdirSync(rawDir)) {
      if (f.endsWith(".json")) {
        try {
          out.push({ name: `raw/${f}`, text: readFileSync(resolve(rawDir, f), "utf8") });
        } catch {
          // unreadable single file — skip, keep the rest.
        }
      }
    }
  } catch {
    // no raw/ dir — fine.
  }
  let db: DbLike | null = null;
  try {
    db = new Database(resolve(workdir, ".brandnana/brandnana.sqlite"));
    const cols: Array<[string, string]> = [
      ["products.description", "SELECT description AS t FROM products WHERE description IS NOT NULL"],
      ["products.raw_json", "SELECT raw_json AS t FROM products WHERE raw_json IS NOT NULL"],
      ["ads.body", "SELECT body AS t FROM ads WHERE body IS NOT NULL"],
      ["ads.raw_json", "SELECT raw_json AS t FROM ads WHERE raw_json IS NOT NULL"],
      ["brands.descriptors_json", "SELECT descriptors_json AS t FROM brands WHERE descriptors_json IS NOT NULL"],
    ];
    for (const [name, sql] of cols) {
      try {
        const rows = db.prepare(sql).all() as Array<{ t: string }>;
        const text = rows.map((r) => r.t).join("\n");
        if (text.length > 0) out.push({ name: `sqlite:${name}`, text });
      } catch {
        // column/table absent in this schema — skip.
      }
    }
  } catch {
    // no SQLite (not a gather workdir, or unreadable) — fine.
  } finally {
    db?.close();
  }
  return out;
}

/** Gather the Stage-2 analysis org (every analysis/*.org). */
function collectAnalysisOrg(analysisDir: string): Array<{ name: string; text: string }> {
  const out: Array<{ name: string; text: string }> = [];
  try {
    for (const f of readdirSync(analysisDir)) {
      if (f.endsWith(".org")) {
        const text = readOrgIfPresent(resolve(analysisDir, f));
        if (text != null) out.push({ name: `analysis/${f}`, text });
      }
    }
  } catch {
    // no analysis dir — handled by the caller as a hard failure.
  }
  return out;
}

// ── Public API: validateAnalysis ─────────────────────────────────────────────

/**
 * Validate a Stage-2 analysis layer against its Stage-1 substrate. Pure: reads
 * org files, returns a structured report. The caller decides exit code from
 * `report.ok`.
 */
export function validateAnalysis(workdir: string): AnalysisReport {
  const resolvedWorkdir = resolve(process.cwd(), workdir);
  const analysisDir = resolve(resolvedWorkdir, "analysis");

  const substrateOrg = collectSubstrateOrg(resolvedWorkdir);
  const analysisOrg = collectAnalysisOrg(analysisDir);

  const substrateAnchors = collectSubstrateAnchors(substrateOrg);
  const insights = collectInsights(analysisOrg);

  const checks: AnalysisCheckResult[] = [];

  // Hard structural failures first.
  if (analysisOrg.length === 0) {
    checks.push(
      check(
        "analysis_dir",
        "workdir contains an analysis/ layer with org files",
        false,
        `no .org files under ${analysisDir} — run the strategist to author analysis/*.org first`,
      ),
    );
  }
  if (substrateOrg.length === 0) {
    checks.push(
      check(
        "substrate_present",
        "Stage-1 substrate org is present to ground against",
        false,
        `no Stage-1 .org files under ${resolvedWorkdir} — analysis cannot be grounded without the substrate`,
      ),
    );
  }

  const { result: coverageResult, typesPresent } = checkCoverage(insights);

  checks.push(
    checkGroundsPresent(insights),
    checkGroundsResolve(insights, substrateAnchors),
    coverageResult,
    checkSubstance(insights),
    checkDuplicateInsights(insights),
    checkQuoteGrounding(insights, [...substrateOrg, ...collectHarvestHaystack(resolvedWorkdir)]),
  );

  const failed = checks.filter((c) => !c.pass).length;
  return {
    workdir: resolvedWorkdir,
    analysisDir,
    ok: failed === 0,
    checks,
    failed,
    typesPresent,
  };
}

// ── Human-readable rendering (mirrors substrate-check's formatReport) ─────────

export function formatAnalysisReport(report: AnalysisReport): string {
  const lines: string[] = [];
  lines.push(`analysis check: ${report.workdir}`);
  lines.push(`  analysis dir: ${report.analysisDir}`);
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

/**
 * Attach the `check` verb to a parent `analysis` command.
 */
export function attachAnalysisCheck(analysis: Command): void {
  analysis
    .command("check [workdir]")
    .description(
      "Validate the Stage-2 analysis layer against its Stage-1 substrate (fails loud on ungrounded/fabricated insights)",
    )
    .action((workdir: string | undefined) =>
      runAction(async () => {
        const report = validateAnalysis(workdir ?? ".");
        emit(report, formatAnalysisReport(report));
        if (!report.ok) {
          // Fail loud: non-zero exit so the strategist cannot finish on
          // ungrounded analysis.
          process.exit(1);
        }
      }),
    );
}

/**
 * Standalone registration: `brandnana analysis check ...`. Creates the
 * `analysis` group (or reuses an existing one if a future `analysis build`
 * lands first).
 */
export function registerAnalysisCheck(program: Command): void {
  const existing = program.commands.find((c) => c.name() === "analysis");
  const analysis =
    existing ??
    program.command("analysis").description("Stage-2 analysis grounding validation");
  attachAnalysisCheck(analysis);
}
