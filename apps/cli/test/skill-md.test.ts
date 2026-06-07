// Unit tests for the SKILL.md generator + metadata extractor.
// Run with: bun test test/skill-md.test.ts

import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gzipSync } from "node:zlib";
import { generateSkillMarkdown, type BookMetadata } from "../src/book/skill-md.js";
import { extractBookMetadata } from "../src/book/extract-metadata.js";

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------

function nikeMetadata(): BookMetadata {
  return {
    slug: "nike",
    brand_name: "Nike",
    domain: "nike.com",
    generated_at_iso: "2026-05-28T12:00:00Z",
    product_count: 1240,
    category_count: 14,
    collection_count: 32,
    competitor_slugs: ["adidas", "puma", "new-balance"],
    ad_count: 87,
    ad_providers: ["meta", "tiktok", "google"],
    has_video: true,
    brandnana_version: "0.4.2",
    capture_cost_usd: 2.37,
  };
}

/**
 * Build a minimal brand book .workbook.html that embeds a wb-source-bundle
 * containing the given virtual org files.
 */
function buildBrandBook(orgFiles: Record<string, string>): string {
  const manifestFiles = Object.entries(orgFiles).map(([path, content]) => ({
    path,
    content: Buffer.from(content, "utf8").toString("base64"),
    mode: 0o644,
  }));

  const manifest = {
    version: 1,
    createdAt: "2026-05-28T12:00:00.000Z",
    rootName: "nike",
    files: manifestFiles,
  };

  const gzipped = gzipSync(Buffer.from(JSON.stringify(manifest), "utf8"));
  const b64 = gzipped.toString("base64");

  return [
    "<!doctype html><html><head></head><body>",
    `<script id="wb-source-bundle"`,
    `        type="application/x-workbook-source"`,
    `        data-format="json+gzip+base64"`,
    `        data-version="1"`,
    `        data-root-name="nike"`,
    `        data-file-count="${manifestFiles.length}">` + b64 + "</script>",
    "</body></html>",
  ].join("\n");
}

// ---------------------------------------------------------------------------
// generateSkillMarkdown — YAML frontmatter
// ---------------------------------------------------------------------------

describe("generateSkillMarkdown — YAML frontmatter", () => {
  test("output begins with --- delimiter", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out.startsWith("---\n")).toBe(true);
  });

  test("name field uses <slug>-brand pattern", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out).toContain("name: nike-brand");
  });

  test("description contains brand_name", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out).toContain("Nike brand intelligence");
  });

  test("description contains slug for competitive positioning trigger", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out).toContain("competitive positioning around nike");
  });

  test("description matches canonical template", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    const expected =
      "description: Nike brand intelligence — logo, fonts, colors, competitor ads, deep product catalog. Use when scaffolding videos/copy/strategy for Nike or analyzing competitive positioning around nike.";
    expect(out).toContain(expected);
  });

  test("frontmatter closes with --- before body", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    // The frontmatter block should be: ---\n...\n---\n
    const secondDash = out.indexOf("---", 3);
    expect(secondDash).toBeGreaterThan(3);
    // After the closing ---, there should be a newline and then the body heading.
    const afterClose = out.slice(secondDash + 3).trimStart();
    expect(afterClose.startsWith("# Nike brand book")).toBe(true);
  });

  test("YAML is parseable (naive key: value check)", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    const start = out.indexOf("---") + 3;
    const end = out.indexOf("---", start);
    const yaml = out.slice(start, end).trim();
    const lines = yaml.split("\n").filter((l) => l.trim().length > 0);
    for (const line of lines) {
      expect(line).toMatch(/^[a-z_]+:\s+.+$/);
    }
  });
});

// ---------------------------------------------------------------------------
// generateSkillMarkdown — body sections
// ---------------------------------------------------------------------------

describe("generateSkillMarkdown — body sections", () => {
  test("# heading uses brand_name", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out).toContain("# Nike brand book");
  });

  test("generated date is human-readable", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out).toContain("Generated May 28, 2026");
  });

  test("What's inside section lists product count", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out).toContain("1240 products");
  });

  test("What's inside section lists category + collection counts", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out).toContain("14 categories");
    expect(out).toContain("32 collections");
  });

  test("competitor slugs appear in body", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out).toContain("adidas");
    expect(out).toContain("puma");
    expect(out).toContain("new-balance");
  });

  test("ad count and providers appear in body", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out).toContain("87 captured");
    expect(out).toContain("Meta");
    expect(out).toContain("TikTok");
    expect(out).toContain("Google");
  });

  test("has_video=true shows video media note", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out).toContain("video + static");
  });

  test("has_video=false shows static images note", () => {
    const meta = nikeMetadata();
    meta.has_video = false;
    const out = generateSkillMarkdown(meta);
    expect(out).toContain("static images embedded");
  });

  test("How to use section contains open command", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out).toContain("open ./nike.workbook.html");
  });

  test("How to use section contains query command", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out).toContain("brandnana book query nike");
  });

  test("How to use section contains refresh (publish) command", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out).toContain("brandnana book publish nike");
  });

  test("OQL queries section is present", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out).toContain("## Common OQL queries");
  });

  test("OQL queries are scoped to the brand slug", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    // Every query line that starts with `brandnana book query` should reference nike
    const queryLines = out
      .split("\n")
      .filter((l) => l.startsWith("brandnana book query "));
    expect(queryLines.length).toBeGreaterThanOrEqual(4);
    for (const line of queryLines) {
      expect(line).toContain("nike");
    }
  });

  test("Capture provenance section shows date and cost", () => {
    const out = generateSkillMarkdown(nikeMetadata());
    expect(out).toContain("## Capture provenance");
    expect(out).toContain("May 28, 2026");
    expect(out).toContain("$2.37");
  });

  test("zero-cost displays as $0.00", () => {
    const meta = nikeMetadata();
    meta.capture_cost_usd = 0;
    const out = generateSkillMarkdown(meta);
    expect(out).toContain("$0.00");
  });

  test("sub-cent cost displays with 4 decimal places", () => {
    const meta = nikeMetadata();
    meta.capture_cost_usd = 0.005;
    const out = generateSkillMarkdown(meta);
    expect(out).toContain("$0.0050");
  });

  test("no competitor slugs shows 'none captured'", () => {
    const meta = nikeMetadata();
    meta.competitor_slugs = [];
    const out = generateSkillMarkdown(meta);
    expect(out).toContain("none captured");
  });

  test("no ad providers shows 'none'", () => {
    const meta = nikeMetadata();
    meta.ad_providers = [];
    const out = generateSkillMarkdown(meta);
    expect(out).toContain("none");
  });
});

// ---------------------------------------------------------------------------
// generateSkillMarkdown — different brand (Adidas)
// ---------------------------------------------------------------------------

describe("generateSkillMarkdown — Adidas brand", () => {
  test("slug and brand_name are correctly scoped", () => {
    const meta: BookMetadata = {
      slug: "adidas",
      brand_name: "Adidas",
      domain: "adidas.com",
      generated_at_iso: "2026-01-15T08:30:00Z",
      product_count: 3200,
      category_count: 22,
      collection_count: 60,
      competitor_slugs: ["nike", "puma"],
      ad_count: 150,
      ad_providers: ["meta", "google"],
      has_video: false,
      brandnana_version: "0.4.0",
      capture_cost_usd: 3.81,
    };
    const out = generateSkillMarkdown(meta);
    expect(out).toContain("name: adidas-brand");
    expect(out).toContain("Adidas brand intelligence");
    expect(out).toContain("competitive positioning around adidas");
    expect(out).toContain("# Adidas brand book");
    expect(out).toContain("open ./adidas.workbook.html");
  });
});

// ---------------------------------------------------------------------------
// extractBookMetadata — minimal brand book
// ---------------------------------------------------------------------------

describe("extractBookMetadata — wb-source-bundle parsing", () => {
  test("throws when no wb-source-bundle block is present", async () => {
    const dir = mkdtempSync(join(tmpdir(), "brandnana-test-"));
    const htmlPath = join(dir, "empty.workbook.html");
    writeFileSync(htmlPath, "<!doctype html><html><body></body></html>", "utf8");

    await expect(extractBookMetadata(htmlPath)).rejects.toThrow("wb-source-bundle");
  });

  test("extracts slug from brand.org :SLUG: property", async () => {
    const dir = mkdtempSync(join(tmpdir(), "brandnana-test-"));
    const htmlPath = join(dir, "nike.workbook.html");

    const brandOrg = [
      "* Nike                                                      :brand:",
      "  :PROPERTIES:",
      "  :SLUG:             nike",
      "  :NAME:             Nike",
      "  :DOMAIN:           nike.com",
      "  :GENERATED_AT:     2026-05-28T12:00:00Z",
      "  :BRANDNANA_VERSION: 0.4.2",
      "  :END:",
    ].join("\n");

    const html = buildBrandBook({ "brand.org": brandOrg });
    writeFileSync(htmlPath, html, "utf8");

    const meta = await extractBookMetadata(htmlPath);
    expect(meta.slug).toBe("nike");
    expect(meta.brand_name).toBe("Nike");
    expect(meta.domain).toBe("nike.com");
    expect(meta.generated_at_iso).toBe("2026-05-28T12:00:00Z");
    expect(meta.brandnana_version).toBe("0.4.2");
  });

  test("extracts product count by counting headlines in catalog/products.org", async () => {
    const dir = mkdtempSync(join(tmpdir(), "brandnana-test-"));
    const htmlPath = join(dir, "nike.workbook.html");

    const brandOrg = "* Nike :brand:\n  :PROPERTIES:\n  :SLUG: nike\n  :NAME: Nike\n  :DOMAIN: nike.com\n  :END:\n";
    const productsOrg = [
      "* Air Max 90",
      "  :PROPERTIES:",
      "  :PRICE: 110",
      "  :END:",
      "* Air Force 1",
      "* Jordan 1 Retro High",
    ].join("\n");

    const html = buildBrandBook({
      "brand.org": brandOrg,
      "catalog/products.org": productsOrg,
    });
    writeFileSync(htmlPath, html, "utf8");

    const meta = await extractBookMetadata(htmlPath);
    expect(meta.product_count).toBe(3);
  });

  test("extracts competitor slugs from competitors/*.org files", async () => {
    const dir = mkdtempSync(join(tmpdir(), "brandnana-test-"));
    const htmlPath = join(dir, "nike.workbook.html");

    const brandOrg = "* Nike :brand:\n  :PROPERTIES:\n  :SLUG: nike\n  :NAME: Nike\n  :DOMAIN: nike.com\n  :END:\n";

    const html = buildBrandBook({
      "brand.org": brandOrg,
      "competitors/adidas.org": "* Adidas :brand:\n",
      "competitors/puma.org": "* Puma :brand:\n",
    });
    writeFileSync(htmlPath, html, "utf8");

    const meta = await extractBookMetadata(htmlPath);
    expect(meta.competitor_slugs).toContain("adidas");
    expect(meta.competitor_slugs).toContain("puma");
    expect(meta.competitor_slugs).toHaveLength(2);
  });

  test("extracts ad_count, ad_providers, has_video, cost from timeline.org", async () => {
    const dir = mkdtempSync(join(tmpdir(), "brandnana-test-"));
    const htmlPath = join(dir, "nike.workbook.html");

    const brandOrg = "* Nike :brand:\n  :PROPERTIES:\n  :SLUG: nike\n  :NAME: Nike\n  :DOMAIN: nike.com\n  :END:\n";
    const timelineOrg = [
      "* Capture run                                          :timeline:",
      "  :PROPERTIES:",
      "  :AD_COUNT:          87",
      "  :AD_PROVIDERS:      meta, tiktok, google",
      "  :HAS_VIDEO:         t",
      "  :CAPTURE_COST_USD:  2.37",
      "  :END:",
    ].join("\n");

    const html = buildBrandBook({
      "brand.org": brandOrg,
      "timeline.org": timelineOrg,
    });
    writeFileSync(htmlPath, html, "utf8");

    const meta = await extractBookMetadata(htmlPath);
    expect(meta.ad_count).toBe(87);
    expect(meta.ad_providers).toContain("meta");
    expect(meta.ad_providers).toContain("tiktok");
    expect(meta.ad_providers).toContain("google");
    expect(meta.has_video).toBe(true);
    expect(meta.capture_cost_usd).toBeCloseTo(2.37, 2);
  });

  test("uses rootName as slug fallback when brand.org lacks :SLUG:", async () => {
    const dir = mkdtempSync(join(tmpdir(), "brandnana-test-"));
    const htmlPath = join(dir, "nike.workbook.html");

    // brand.org has no :SLUG: property
    const brandOrg = "* Nike\n";

    // rootName in the manifest is "nike"
    const html = buildBrandBook({ "brand.org": brandOrg });
    writeFileSync(htmlPath, html, "utf8");

    const meta = await extractBookMetadata(htmlPath);
    expect(meta.slug).toBe("nike"); // falls back to manifest rootName
  });

  test("returns zero for counts when org files are absent", async () => {
    const dir = mkdtempSync(join(tmpdir(), "brandnana-test-"));
    const htmlPath = join(dir, "nike.workbook.html");

    const html = buildBrandBook({}); // empty bundle
    writeFileSync(htmlPath, html, "utf8");

    const meta = await extractBookMetadata(htmlPath);
    expect(meta.product_count).toBe(0);
    expect(meta.ad_count).toBe(0);
    expect(meta.competitor_slugs).toHaveLength(0);
    expect(meta.has_video).toBe(false);
  });
});
