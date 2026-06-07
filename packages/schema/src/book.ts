// BookManifest type — cross-package shape for brand-book metadata.
//
// This is the canonical manifest embedded in a brand book (both as SKILL.md
// frontmatter and as the workbook-spec JSON). Kept in sync with:
//   - apps/cli/src/book/skill-md.ts  (BookMetadata — CLI-side)
//   - apps/api/src/book/skill-md.ts  (BookMetadata — Worker-side)
//   - apps/api/src/book/pipeline.ts  (BookManifest — pipeline output)
//
// The slight naming distinction (BookManifest vs BookMetadata) is intentional:
//   BookManifest  = the cross-package, network-serialisable shape
//   BookMetadata  = the CLI/API-local shape used for SKILL.md generation
// They are structurally compatible; this file is the authoritative union.

export interface BookManifest {
  /** Primary domain of the captured brand, e.g. "nike.com" */
  domain: string;
  /** URL-safe slug derived from the domain SLD, e.g. "nike" */
  slug: string;
  /** ISO-8601 generation timestamp */
  generated_at: string;
  /** Display name, e.g. "Nike" */
  brand_name?: string;
  /** Total vendor cost of the capture run in USD */
  capture_cost_usd: number;
  /** Number of products captured (0 if catalog crawl not run) */
  product_count: number;
  /** Number of product categories */
  category_count: number;
  /** Number of product collections */
  collection_count: number;
  /** Number of ads captured */
  ad_count: number;
  /** Ad platform slugs, e.g. ["meta", "tiktok"] */
  ad_providers: string[];
  /** Slugs of captured competitor brands */
  competitor_slugs: string[];
  /** true if video media was captured (--with-video) */
  has_video: boolean;
  /** Number of .org source files in the bundle */
  file_count: number;
  /** Version of the tool that captured this book */
  generator?: string;
}
