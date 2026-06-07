// analysis → slide-data mapper (BRANDBOOK-STATUS §3.3)
//
// The deck used to be a FIXED ~10-slide template (presentation-shell.ts) that
// ignored the strategist's grounded analysis. This maps the Stage-2
// `analysis/*.org` insights → slide DATA, one slide per insight, so the deck is
// data-driven: what the strategist actually argued, in the order the families
// imply. Pure data (no HTML here) — the renderer consumes InsightSlide[].
//
// Insight org shape (write-analysis.org, verbatim):
//   * <headline title>                          :insight:<type>:
//     :PROPERTIES:
//     :TYPE:    voice
//     :GROUNDS: acme, brand:palette
//     :END:
//     <prose body — one or more lines, until the next headline>

export interface Insight {
  /** The :TYPE: (drawer wins; falls back to the :insight:<type>: tag). */
  type: string;
  /** The headline text (tags stripped). */
  title: string;
  /** Resolved Stage-1 anchors from :GROUNDS: (comma/space separated). */
  grounds: string[];
  /** The prose body after the drawer, trimmed. */
  body: string;
}

export interface InsightSlide {
  /** Stable slide key, e.g. "insight-voice" (deduped with -2, -3 on collision). */
  key: string;
  type: string;
  title: string;
  body: string;
  grounds: string[];
}

// Canonical family order — slides come out in this order; unknown types sort
// after, alphabetically, so a new family still renders deterministically.
const FAMILY_ORDER = [
  "positioning",
  "audience",
  "personas",
  "voice",
  "tone",
  "messaging-pillars",
  "copy-ideas",
  "ad-ideas",
  "ad-vision",
  "creative-patterns",
  "hero-products",
  "price-architecture",
  "catalog-stats",
  "whitespace",
  "competitive-frame",
  "content-themes",
  "mood-board",
  "firmographics",
  "testimonials",
  "archetype",
  "dos-donts",
];

const HEADLINE = /^\*+\s+(.*?)\s*$/;
const INSIGHT_TAG = /:insight:([a-z0-9-]+):/i;
const TAG_RUN = /(\s+):[\w:@-]+:\s*$/;

/**
 * Parse every `:insight:` headline out of one analysis org file. Tolerant of
 * extra tags, atom/spacing variation, and missing drawers (body still captured).
 */
export function parseInsights(org: string): Insight[] {
  const lines = org.split("\n");
  const out: Insight[] = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i] ?? "";
    const hl = HEADLINE.exec(line);
    if (!hl || !INSIGHT_TAG.test(line)) {
      i++;
      continue;
    }

    const tagType = INSIGHT_TAG.exec(line)?.[1]?.toLowerCase() ?? "";
    // Title = headline text with the trailing tag run removed.
    const title = (hl[1] ?? "").replace(TAG_RUN, "").trim();

    // Scan the body until the next headline, picking up the drawer.
    let drawerType = "";
    let grounds: string[] = [];
    const bodyLines: string[] = [];
    let j = i + 1;
    let inDrawer = false;

    while (j < lines.length && !HEADLINE.test(lines[j] ?? "")) {
      const t = (lines[j] ?? "").trim();
      if (t === ":PROPERTIES:") {
        inDrawer = true;
      } else if (t === ":END:") {
        inDrawer = false;
      } else if (inDrawer) {
        const m = /^:([A-Z_]+):\s*(.*)$/.exec(t);
        if (m) {
          if (m[1] === "TYPE") drawerType = (m[2] ?? "").trim().toLowerCase();
          if (m[1] === "GROUNDS") grounds = splitGrounds(m[2] ?? "");
        }
      } else if (t.length > 0) {
        bodyLines.push(t);
      }
      j++;
    }

    out.push({
      type: drawerType || tagType,
      title,
      grounds,
      body: bodyLines.join(" ").trim(),
    });
    i = j;
  }

  return out;
}

function splitGrounds(raw: string): string[] {
  return raw
    .split(/[,\s]+/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

/**
 * Map parsed insights → ordered slide data, one slide per insight. Families sort
 * by FAMILY_ORDER (unknown types after, alphabetically); ties keep input order.
 * Slide keys are deduped so two insights of the same type get distinct keys.
 */
export function insightsToSlides(insights: Insight[]): InsightSlide[] {
  // Drop parse artifacts: a headline that matched :insight: but carries neither
  // a title nor a body would render as a blank slide. (An insight with a title
  // but empty body is kept — the headline IS the argument.)
  const ordered = insights
    .filter((ins) => ins.title.trim() !== "" || ins.body.trim() !== "")
    .map((ins, idx) => ({ ins, idx }))
    .sort((a, b) => familyRank(a.ins.type) - familyRank(b.ins.type) || a.idx - b.idx);

  const seen = new Map<string, number>();
  return ordered.map(({ ins }) => {
    const base = `insight-${ins.type || "untyped"}`;
    const n = (seen.get(base) ?? 0) + 1;
    seen.set(base, n);
    return {
      key: n === 1 ? base : `${base}-${n}`,
      type: ins.type,
      title: ins.title,
      body: ins.body,
      grounds: ins.grounds,
    };
  });
}

function familyRank(type: string): number {
  const i = FAMILY_ORDER.indexOf(type);
  // Unknown families: push past the known block, ordered alphabetically by
  // charCode of the first char so ordering stays deterministic.
  return i >= 0 ? i : FAMILY_ORDER.length + (type.charCodeAt(0) || 0);
}

/** Convenience: parse many analysis files and flatten to ordered slide data. */
export function analysisFilesToSlides(orgFiles: string[]): InsightSlide[] {
  const all = orgFiles.flatMap((org) => parseInsights(org));
  return insightsToSlides(all);
}
