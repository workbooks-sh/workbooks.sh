// extract-metadata.ts — parse an installed .workbook.html and extract BookMetadata.
//
// The brand book HTML embeds all .org source files using the workbook-cli source
// bundle format. The bundle is stored in:
//
//   <script id="wb-source-bundle"
//           type="application/x-workbook-source"
//           data-format="json+gzip+base64"
//           data-version="1"
//           ...>BASE64_OF_GZIPPED_JSON</script>
//
// The gzipped JSON decodes to a manifest of shape:
//
//   {
//     version: 1,
//     createdAt: string,
//     rootName: string,
//     files: Array<{
//       path: string,
//       content: string,   // base64-encoded file bytes; absent when truncated
//       mode: number,
//       truncated?: true,
//       originalSize?: number,
//     }>
//   }
//
// The org tree inside the bundle contains canonical files the brandnana CLI
// produces:
//   - brand.org            (brand identity — name, domain, palette, descriptors)
//   - timeline.org         (capture provenance — verbs run, cost)
//   - catalog/products.org (product list — one headline per product)
//   - competitors/*.org    (one file per competitor brand)
//
// This module extracts BookMetadata from those files without spawning any
// external process.
//
// TODO (wb-0wst.3): once the `brandnana book` CLI verb lands, align any field
// names with what the book-build pipeline writes to brand.org / timeline.org.
// Current field extraction is based on the org property conventions used in
// brandnana brand.fetch output and the wavelet-director agent org templates.

import { readFile } from "node:fs/promises";
import { gunzipSync } from "node:zlib";
import type { BookMetadata } from "./skill-md.js";

// ---------------------------------------------------------------------------
// Source bundle parsing
// ---------------------------------------------------------------------------

interface BundleFile {
  path: string;
  content?: string; // base64; absent when truncated
  mode: number;
  truncated?: boolean;
  originalSize?: number;
}

interface BundleManifest {
  version: number;
  createdAt: string;
  rootName: string;
  files: BundleFile[];
}

/** Extract the base64 source bundle payload from raw HTML. */
function extractBundleBase64(html: string): string | null {
  const MARKER_OPEN = '<script id="wb-source-bundle"';
  const MARKER_CLOSE = "</script>";

  const start = html.indexOf(MARKER_OPEN);
  if (start < 0) return null;

  const tagEnd = html.indexOf(">", start);
  if (tagEnd < 0) return null;

  const close = html.indexOf(MARKER_CLOSE, tagEnd);
  if (close < 0) return null;

  return html.slice(tagEnd + 1, close).replace(/\s/g, "");
}

/** Decompress and parse the gzipped JSON bundle. */
function decodeBundleManifest(b64: string): BundleManifest {
  const buf = Buffer.from(b64, "base64");
  const json = gunzipSync(buf).toString("utf8");
  return JSON.parse(json) as BundleManifest;
}

/** Decode a bundle file's base64 content to UTF-8 text. */
function decodeFileContent(file: BundleFile): string | null {
  if (file.truncated || file.content == null) return null;
  return Buffer.from(file.content, "base64").toString("utf8");
}

// ---------------------------------------------------------------------------
// Org property extraction
// ---------------------------------------------------------------------------

/** Extract the value of a single PROPERTIES drawer property.
 *  Matches: `:KEY: value` (case-insensitive key). */
function orgProp(orgText: string, key: string): string | null {
  const re = new RegExp(`^\\s*:${key}:\\s+(.+)$`, "im");
  const m = orgText.match(re);
  return m ? (m[1]?.trim() ?? null) : null;
}

/** Count the number of level-2 (or any level) headlines in an org file.
 *  A headline starts with one or more `*` followed by a space. */
function countHeadlines(orgText: string, level?: number): number {
  const prefix = level != null ? `\\*{${level}}` : "\\*+";
  const re = new RegExp(`^${prefix} `, "gm");
  return (orgText.match(re) ?? []).length;
}

/** Extract a #+KEYWORD value from the org file header.
 *  Matches: `#+KEY: value` (case-insensitive). */
function orgKeyword(orgText: string, key: string): string | null {
  const re = new RegExp(`^#\\+${key}:\\s+(.+)$`, "im");
  const m = orgText.match(re);
  return m ? (m[1]?.trim() ?? null) : null;
}

/** Parse a comma-separated property value into a trimmed string array. */
function splitCommaList(value: string | null): string[] {
  if (!value) return [];
  return value
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Parse an installed brand book .workbook.html, decompress the embedded org
 * bundle, and extract BookMetadata from the org files inside.
 *
 * The source bundle format is the workbook-cli `wb-source-bundle` format
 * (see `cli/wb/forge/packages/workbook-cli/src/bundle/embedSource.mjs`).
 *
 * Throws if:
 *   - the file cannot be read
 *   - no `wb-source-bundle` script block is found
 *   - the bundle cannot be decoded
 *
 * Missing or unreadable fields fall back to safe defaults (empty arrays, 0,
 * empty strings) so callers always get a fully-shaped BookMetadata.
 */
export async function extractBookMetadata(workbookHtmlPath: string): Promise<BookMetadata> {
  const html = await readFile(workbookHtmlPath, "utf8");

  const b64 = extractBundleBase64(html);
  if (b64 == null || b64.length === 0) {
    throw new Error(
      `No wb-source-bundle block found in ${workbookHtmlPath}. ` +
        "Is this a brandnana brand book? Expected a <script id=\"wb-source-bundle\"> tag.",
    );
  }

  let manifest: BundleManifest;
  try {
    manifest = decodeBundleManifest(b64);
  } catch (err) {
    throw new Error(
      `Failed to decode wb-source-bundle in ${workbookHtmlPath}: ${(err as Error).message}`,
    );
  }

  const fileMap = new Map<string, BundleFile>();
  for (const f of manifest.files) {
    fileMap.set(f.path, f);
  }

  // ── brand.org ──────────────────────────────────────────────────────────────
  // Expected properties: :SLUG:, :NAME:, :DOMAIN:, :GENERATED_AT:, :VERSION:
  const brandFile = fileMap.get("brand.org");
  const brandOrg = brandFile ? decodeFileContent(brandFile) : null;

  const slug = (orgProp(brandOrg ?? "", "SLUG") ?? manifest.rootName).toLowerCase();
  const brand_name = orgProp(brandOrg ?? "", "NAME") ?? orgKeyword(brandOrg ?? "", "TITLE") ?? slug;
  const domain = orgProp(brandOrg ?? "", "DOMAIN") ?? `${slug}.com`;
  const generated_at_iso =
    orgProp(brandOrg ?? "", "GENERATED_AT") ??
    orgProp(brandOrg ?? "", "CAPTURED_AT") ??
    manifest.createdAt;
  const brandnana_version = orgProp(brandOrg ?? "", "BRANDNANA_VERSION") ?? "unknown";

  // ── catalog/products.org ───────────────────────────────────────────────────
  // Each product is a level-1 headline.
  const productsFile =
    fileMap.get("catalog/products.org") ?? fileMap.get("products.org");
  const productsOrg = productsFile ? decodeFileContent(productsFile) : null;
  const product_count = productsOrg != null ? countHeadlines(productsOrg, 1) : 0;

  // Category count: level-2 headlines under the catalog grouping in brand.org,
  // or #+CATEGORIES keyword.
  const category_count_str =
    orgProp(brandOrg ?? "", "CATEGORY_COUNT") ??
    orgKeyword(brandOrg ?? "", "CATEGORIES");
  const category_count = category_count_str != null
    ? Math.max(0, Number.parseInt(category_count_str, 10) || 0)
    : 0;

  const collection_count_str =
    orgProp(brandOrg ?? "", "COLLECTION_COUNT") ??
    orgKeyword(brandOrg ?? "", "COLLECTIONS");
  const collection_count = collection_count_str != null
    ? Math.max(0, Number.parseInt(collection_count_str, 10) || 0)
    : 0;

  // ── competitors/*.org ──────────────────────────────────────────────────────
  // Each file path under competitors/ is one competitor slug.
  const competitor_slugs = [...fileMap.keys()]
    .filter((p) => p.startsWith("competitors/") && p.endsWith(".org"))
    .map((p) => p.replace(/^competitors\//, "").replace(/\.org$/, ""));

  // ── timeline.org ───────────────────────────────────────────────────────────
  // Expected properties: :AD_COUNT:, :AD_PROVIDERS:, :HAS_VIDEO:, :CAPTURE_COST_USD:
  const timelineFile = fileMap.get("timeline.org");
  const timelineOrg = timelineFile ? decodeFileContent(timelineFile) : null;

  const ad_count_str = orgProp(timelineOrg ?? "", "AD_COUNT") ?? orgProp(brandOrg ?? "", "AD_COUNT");
  const ad_count = ad_count_str != null ? Math.max(0, Number.parseInt(ad_count_str, 10) || 0) : 0;

  const ad_providers_str =
    orgProp(timelineOrg ?? "", "AD_PROVIDERS") ?? orgProp(brandOrg ?? "", "AD_PROVIDERS");
  const ad_providers = splitCommaList(ad_providers_str);

  const has_video_str =
    orgProp(timelineOrg ?? "", "HAS_VIDEO") ?? orgProp(brandOrg ?? "", "HAS_VIDEO");
  const has_video = has_video_str === "t" || has_video_str === "true" || has_video_str === "yes";

  const cost_str =
    orgProp(timelineOrg ?? "", "CAPTURE_COST_USD") ??
    orgProp(brandOrg ?? "", "CAPTURE_COST_USD");
  const capture_cost_usd = cost_str != null ? Math.max(0, Number.parseFloat(cost_str) || 0) : 0;

  return {
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
    brandnana_version,
    capture_cost_usd,
  };
}
