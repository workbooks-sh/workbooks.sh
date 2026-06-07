// SKILL.md generator for installed brand books.
//
// Runs CLIENT-SIDE at install time inside the brandnana CLI. Reads
// BookMetadata extracted from the installed .workbook.html and emits a
// SKILL.md that Claude Code's skill router can discover + trigger on.
//
// Output format:
//   - YAML frontmatter (name + description) understood by Claude Code
//   - Body: what's in the workbook, how to query it, OQL examples

export interface BookMetadata {
  /** URL-safe slug: 'nike' */
  slug: string;
  /** Display name: 'Nike' */
  brand_name: string;
  /** Primary domain: 'nike.com' */
  domain: string;
  /** ISO-8601 timestamp of capture */
  generated_at_iso: string;
  product_count: number;
  category_count: number;
  collection_count: number;
  /** Slugs of captured competitor brands */
  competitor_slugs: string[];
  ad_count: number;
  /** Ad platforms: ['meta', 'tiktok', 'google'] */
  ad_providers: string[];
  /** true if --with-video was set during capture */
  has_video: boolean;
  /** Version of the brandnana CLI that captured this book */
  brandnana_version: string;
  /** Total cost of the capture run in USD */
  capture_cost_usd: number;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Format an ISO timestamp as a human-readable date, e.g. "May 28, 2026". */
function humanDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });
}

/** Format capture cost as a dollar string: "$1.23" or "$0.07". */
function formatCost(usd: number): string {
  if (usd === 0) return "$0.00";
  if (usd < 0.01) return `$${usd.toFixed(4)}`;
  return `$${usd.toFixed(2)}`;
}

/** Capitalise the first letter of a provider slug: 'meta' → 'Meta'. */
function titleCase(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

/** Format a comma-separated provider list: ['meta', 'tiktok'] → 'Meta, TikTok'. */
function formatProviders(providers: string[]): string {
  if (providers.length === 0) return "none";
  return providers
    .map((p) => (p.toLowerCase() === "tiktok" ? "TikTok" : titleCase(p)))
    .join(", ");
}

/** Format competitor slugs as a comma-separated list: "adidas, puma". */
function formatCompetitors(slugs: string[]): string {
  if (slugs.length === 0) return "none captured";
  return slugs.join(", ");
}

// ---------------------------------------------------------------------------
// Generator
// ---------------------------------------------------------------------------

/**
 * Generate a SKILL.md for an installed brand book.
 *
 * The output has YAML frontmatter (name + description) followed by a body
 * covering what's in the workbook, how to open it, CLI query examples, and
 * capture provenance.
 */
export function generateSkillMarkdown(meta: BookMetadata): string {
  const {
    slug,
    brand_name,
    domain,
    generated_at_iso,
    product_count,
    category_count,
    collection_count,
    competitor_slugs,
    ad_count,
    ad_providers,
    has_video,
    capture_cost_usd,
  } = meta;

  const dateHuman = humanDate(generated_at_iso);
  const providersHuman = formatProviders(ad_providers);
  const competitorsHuman = formatCompetitors(competitor_slugs);
  const mediaNote = has_video ? "video + static (R2-linked)" : "static images embedded";

  // Honest zero-state: if every count is 0, the API was running but no vendor
  // secrets were configured. Surface that instead of pretending the book has data.
  const hasAnyData =
    product_count > 0 || ad_count > 0 || competitor_slugs.length > 0;

  const insideLines = hasAnyData
    ? [
        "## What's inside",
        `- **workbook.html** — open in browser for the full visual experience (Theater for ads, palette grid, catalog browser).`,
        `- **Catalog**: ${product_count} products across ${category_count} categories, ${collection_count} collections.`,
        `- **Competitors**: ${competitorsHuman}.`,
        `- **Ads**: ${ad_count} captured from ${providersHuman}.`,
        `- **Media**: ${mediaNote}.`,
        "",
      ]
    : [
        "## Capture status — partial",
        "",
        "This brand book was generated but the API returned no vendor data — most",
        "likely the API worker is missing one or more vendor credentials",
        "(`META_*`, `EXA_API_KEY`, `FIRECRAWL_API_KEY`, `CONTEXT_DEV_API_KEY`, etc.).",
        "Re-run after the operator pushes the missing secrets, or contact your",
        "API administrator.",
        "",
        "- **workbook.html** — still openable; contains the bare-bones schema and metadata only.",
        "",
      ];

  return [
    "---",
    `name: ${slug}-brand`,
    `description: ${brand_name} brand intelligence — logo, fonts, colors, competitor ads, deep product catalog. Use when scaffolding videos/copy/strategy for ${brand_name} or analyzing competitive positioning around ${slug}.`,
    "---",
    "",
    `# ${brand_name} brand book`,
    "",
    `Generated ${dateHuman} via \`brandnana book ${domain}\`.`,
    "",
    ...insideLines,
    "## How to use this skill",
    "",
    "- **Open in browser**:",
    "  ```",
    `  open ./${slug}.workbook.html`,
    "  ```",
    "",
    "- **Query the data via CLI**:",
    "  ```",
    `  brandnana book query ${slug} '(under "Catalog/by-price-band/Under $100")'`,
    "  ```",
    "",
    "- **Refresh**: re-author the deck HTML, then republish:",
    "  ```",
    `  brandnana book publish ${slug} deck.html`,
    "  ```",
    "",
    "## Common OQL queries scoped to this brand book",
    "",
    "```sh",
    "# All products under $100",
    `brandnana book query ${slug} '(under "Catalog/by-price-band/Under $100")'`,
    "",
    "# Black colorways across the catalog",
    `brandnana book query ${slug} '(under "Catalog/by-color/Black")'`,
    "",
    "# Competitor ad themes",
    `brandnana book query ${slug} '(tagged competitor) and (has property :THEME:)'`,
    "",
    "# Out-of-stock products",
    `brandnana book query ${slug} '(under "Catalog/by-stock-status/out_of_stock")'`,
    "",
    "# Full brand palette",
    `brandnana book query ${slug} '(under "Visual identity/Extended palette")'`,
    "```",
    "",
    "## Source data",
    "",
    "This workbook bundles `.org` files (brand.org, competitors/*.org, catalog/products.org, timeline.org)",
    "gzipped inside the .workbook.html. The brandnana CLI decompresses + queries them on demand.",
    "",
    "## Capture provenance",
    `- Captured: ${dateHuman}`,
    `- Verbs run: brand.fetch, ads.search, catalog.crawl, design.palette`,
    `- Total cost: ${formatCost(capture_cost_usd)}`,
  ].join("\n");
}
