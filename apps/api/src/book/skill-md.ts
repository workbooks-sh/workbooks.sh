// Server-side SKILL.md generator for brand books.
//
// Mirrors the CLI-side generator at apps/cli/src/book/skill-md.ts in order
// to produce SKILL.md inside the Worker without importing Node-side modules.
// The interface (BookMetadata) is kept identical so the two implementations
// stay symmetric. When the schema package gains a shared `book` export this
// can be consolidated.

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
  /** Version of the brandnana CLI / API that captured this book */
  brandnana_version: string;
  /** Total cost of the capture run in USD */
  capture_cost_usd: number;
}

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

function formatCost(usd: number): string {
  if (usd === 0) return "$0.00";
  if (usd < 0.01) return `$${usd.toFixed(4)}`;
  return `$${usd.toFixed(2)}`;
}

function titleCase(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function formatProviders(providers: string[]): string {
  if (providers.length === 0) return "none";
  return providers
    .map((p) => (p.toLowerCase() === "tiktok" ? "TikTok" : titleCase(p)))
    .join(", ");
}

function formatCompetitors(slugs: string[]): string {
  if (slugs.length === 0) return "none captured";
  return slugs.join(", ");
}

/**
 * Generate a SKILL.md for an installed brand book.
 *
 * Output has YAML frontmatter + body covering contents, CLI queries, and
 * capture provenance. Symmetric with the CLI-side version.
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
    "## What's inside",
    `- **${slug}.html** — open in browser for the full visual experience (catalog browser, palette, ad gallery).`,
    `- **Catalog**: ${product_count} products across ${category_count} categories, ${collection_count} collections.`,
    `- **Competitors**: ${competitorsHuman}.`,
    `- **Ads**: ${ad_count} captured from ${providersHuman}.`,
    `- **Media**: ${mediaNote}.`,
    "",
    "## How to use this skill",
    "",
    "- **Open in browser**:",
    "  ```",
    `  open ./${slug}.html`,
    "  ```",
    "",
    "- **Query the data via CLI**:",
    "  ```",
    `  brandnana book query ${slug} '(under "Catalog/by-price-band/Under $100")'`,
    "  ```",
    "",
    "- **Refresh**:",
    "  ```",
    `  brandnana book expand ${slug}`,
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
    `gzipped inside ${slug}.html. The brandnana CLI decompresses + queries them on demand.`,
    "",
    "## Capture provenance",
    `- Captured: ${dateHuman}`,
    `- Verbs run: brand.fetch, ads.search, catalog.crawl, design.palette`,
    `- Total cost: ${formatCost(capture_cost_usd)}`,
  ].join("\n");
}
