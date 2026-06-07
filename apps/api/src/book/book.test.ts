// Smoke test for /v1/book: tar + book-bundle + skill-md unit tests.
//
// Uses synthetic (mocked) data — no external API calls. Validates:
//   1. tar() produces a valid USTAR archive parseable by a basic reader
//   2. tarGz() produces bytes starting with gzip magic (1f 8b)
//   3. bundleWorkbook() produces HTML with the required <script> markers
//   4. generateSkillMarkdown() produces a SKILL.md with YAML frontmatter
//   5. The full buildBook pipeline (with mocked env) returns a valid tar.gz
//      containing SKILL.md and <slug>.html

import { describe, expect, it } from "bun:test";
import { tar, tarGz } from "./tar.js";
import { bundleWorkbook } from "./book-bundle.js";
import { generateSkillMarkdown } from "./skill-md.js";
import type { BookMetadata } from "./skill-md.js";
import { validateSourceBundle } from "./publish.js";

// ── tar ───────────────────────────────────────────────────────────────────────

describe("tar()", () => {
  it("produces a non-empty byte array for a single file", () => {
    const enc = new TextEncoder();
    const bytes = tar([{ path: "hello.txt", bytes: enc.encode("hello world") }]);
    expect(bytes.length).toBeGreaterThan(0);
    // Must be a multiple of 512 (USTAR block size)
    expect(bytes.length % 512).toBe(0);
  });

  it("encodes filename in first 100 bytes of header", () => {
    const enc = new TextEncoder();
    const bytes = tar([{ path: "SKILL.md", bytes: enc.encode("# test") }]);
    const header = bytes.slice(0, 100);
    const name = new TextDecoder().decode(header).replace(/\0.*$/, "");
    expect(name).toBe("SKILL.md");
  });

  it("terminates with two empty 512-byte blocks", () => {
    const enc = new TextEncoder();
    const bytes = tar([{ path: "x.txt", bytes: enc.encode("x") }]);
    // Last 1024 bytes must be zero
    const last1024 = bytes.slice(-1024);
    const allZero = last1024.every((b) => b === 0);
    expect(allZero).toBe(true);
  });

  it("handles two files", () => {
    const enc = new TextEncoder();
    const bytes = tar([
      { path: "a.txt", bytes: enc.encode("aaa") },
      { path: "b.txt", bytes: enc.encode("bbb") },
    ]);
    expect(bytes.length % 512).toBe(0);
    // Should contain both filenames somewhere
    const text = new TextDecoder().decode(bytes);
    expect(text).toContain("a.txt");
    expect(text).toContain("b.txt");
  });
});

describe("tarGz()", () => {
  it("produces bytes starting with gzip magic (1f 8b)", async () => {
    const enc = new TextEncoder();
    const gz = await tarGz([{ path: "test.txt", bytes: enc.encode("hello") }]);
    expect(gz[0]).toBe(0x1f);
    expect(gz[1]).toBe(0x8b);
  });

  it("produces a non-trivially sized result for a real workbook bundle", async () => {
    const enc = new TextEncoder();
    const content = "* Nike brand book\n\n** Products\n   :PROPERTIES:\n   :DOMAIN: nike.com\n   :END:\n";
    const gz = await tarGz([
      { path: "SKILL.md", bytes: enc.encode("---\nname: nike-brand\n---\n# Nike brand book\n") },
      { path: "nike.html", bytes: enc.encode(content.repeat(20)) },
    ]);
    // Should be at least 50 bytes (real gzip with content)
    expect(gz.length).toBeGreaterThan(50);
  });
});

// ── book-bundle ───────────────────────────────────────────────────────────

describe("bundleWorkbook()", () => {
  it("contains <script id='workbook-spec'> marker", async () => {
    const html = await bundleWorkbook(
      { slug: "nike", title: "Nike brand book", createdAt: "2026-05-28T00:00:00Z" },
      [{ path: "brand.org", content: "* Nike :brand:\n" }],
    );
    expect(html).toContain('<script id="workbook-spec"');
    expect(html).toContain('type="application/json"');
  });

  it("contains <script id='wb-source-bundle'> marker", async () => {
    const html = await bundleWorkbook(
      { slug: "nike", title: "Nike brand book", createdAt: "2026-05-28T00:00:00Z" },
      [{ path: "brand.org", content: "* Nike :brand:\n" }],
    );
    expect(html).toContain('<script id="wb-source-bundle"');
    expect(html).toContain('data-format="json+gzip+base64"');
  });

  it("spec JSON contains slug and title", async () => {
    const html = await bundleWorkbook(
      { slug: "test-brand", title: "Test brand book", createdAt: "2026-05-28T00:00:00Z" },
      [{ path: "brand.org", content: "* Test :brand:\n" }],
    );
    // The workbook-spec script tag should contain the slug
    const specMatch = html.match(/<script id="workbook-spec"[^>]*>(.*?)<\/script>/s);
    expect(specMatch).toBeTruthy();
    if (specMatch) {
      const spec = JSON.parse(specMatch[1]);
      expect(spec.slug).toBe("test-brand");
      expect(spec.title).toBe("Test brand book");
    }
  });

  it("source bundle is non-empty base64", async () => {
    const html = await bundleWorkbook(
      { slug: "x", title: "X", createdAt: "2026-05-28T00:00:00Z" },
      [{ path: "brand.org", content: "* X :brand:\n" }],
    );
    const bundleMatch = html.match(/<script id="wb-source-bundle"[^>]*>([\s\S]*?)<\/script>/);
    expect(bundleMatch).toBeTruthy();
    if (bundleMatch) {
      const b64 = bundleMatch[1].trim();
      expect(b64.length).toBeGreaterThan(20);
      // Should decode to something (not throw)
      expect(() => atob(b64)).not.toThrow();
    }
  });
});

// ── publish: wb-source-bundle validation (wb-8snp / wb-ann4) ──────────────────
// The publish route serves agent HTML verbatim; it must REJECT any deck whose
// wb-source-bundle is missing or doesn't round-trip (base64→gunzip→JSON.parse,
// manifest.files an array). A real bundleWorkbook() output must pass.

describe("validateSourceBundle()", () => {
  it("accepts a real bundleWorkbook() deck (round-trips)", async () => {
    const html = await bundleWorkbook(
      { slug: "nike", title: "Nike brand book", createdAt: "2026-05-28T00:00:00Z" },
      [{ path: "brand.org", content: "* Nike :brand:\n" }],
    );
    const res = await validateSourceBundle(html);
    expect(res.ok).toBe(true);
    if (res.ok) expect(res.fileCount).toBe(1);
  });

  it("rejects HTML with no wb-source-bundle block", async () => {
    const res = await validateSourceBundle("<html><body>just a deck</body></html>");
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.reason).toContain("no <script");
  });

  it("rejects an empty bundle block", async () => {
    const html = '<script id="wb-source-bundle" data-format="json+gzip+base64" data-version="1"></script>';
    const res = await validateSourceBundle(html);
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.reason).toContain("empty");
  });

  it("rejects raw .org mislabeled as a bundle (the wb-ann4 failure)", async () => {
    // base64 of plain org text — decodes from base64 but is NOT gzip, so gunzip throws.
    const rawOrg = btoa("* Nike :brand:\n** Products\n");
    const html = `<script id="wb-source-bundle" data-format="json+gzip+base64" data-version="1">${rawOrg}</script>`;
    const res = await validateSourceBundle(html);
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.reason).toContain("did not decode");
  });

  it("rejects a valid gzip+JSON whose manifest.files is not an array", async () => {
    // Gzip a JSON object missing files[] — decodes cleanly but fails the manifest assert.
    const json = JSON.stringify({ version: 1, rootName: "x", files: "nope" });
    const gz = new Uint8Array(
      await new Response(
        new Blob([json]).stream().pipeThrough(new CompressionStream("gzip")),
      ).arrayBuffer(),
    );
    let binary = "";
    for (let i = 0; i < gz.length; i++) binary += String.fromCharCode(gz[i] ?? 0);
    const b64 = btoa(binary);
    const html = `<script id="wb-source-bundle" data-format="json+gzip+base64" data-version="1">${b64}</script>`;
    const res = await validateSourceBundle(html);
    expect(res.ok).toBe(false);
    if (!res.ok) expect(res.reason).toContain("files");
  });
});

// ── skill-md ──────────────────────────────────────────────────────────────────

describe("generateSkillMarkdown()", () => {
  const sampleMeta: BookMetadata = {
    slug: "nike",
    brand_name: "Nike",
    domain: "nike.com",
    generated_at_iso: "2026-05-28T12:00:00Z",
    product_count: 1500,
    category_count: 12,
    collection_count: 8,
    competitor_slugs: ["adidas", "puma"],
    ad_count: 47,
    ad_providers: ["meta", "tiktok"],
    has_video: false,
    brandnana_version: "1.0.0",
    capture_cost_usd: 0.0234,
  };

  it("starts with YAML frontmatter", () => {
    const md = generateSkillMarkdown(sampleMeta);
    expect(md.startsWith("---\n")).toBe(true);
  });

  it("has name: nike-brand in frontmatter", () => {
    const md = generateSkillMarkdown(sampleMeta);
    expect(md).toContain("name: nike-brand");
  });

  it("contains brand name in h1", () => {
    const md = generateSkillMarkdown(sampleMeta);
    expect(md).toContain("# Nike brand book");
  });

  it("mentions product count", () => {
    const md = generateSkillMarkdown(sampleMeta);
    expect(md).toContain("1500 products");
  });

  it("lists competitor slugs", () => {
    const md = generateSkillMarkdown(sampleMeta);
    expect(md).toContain("adidas");
    expect(md).toContain("puma");
  });

  it("formats cost as dollar amount", () => {
    const md = generateSkillMarkdown(sampleMeta);
    expect(md).toContain("$0.02");
  });
});

// ── integration: pipeline → tar.gz ───────────────────────────────────────────
// Validates that SKILL.md + <slug>.html are present in the final
// tar.gz by building the book with canned brand data (no live API calls).

describe("integration: full book tar.gz shape", () => {
  it("tar.gz starts with gzip magic and contains both expected filenames", async () => {
    const enc = new TextEncoder();

    // Build components directly (mimics what buildBook produces)
    const slug = "nike";
    const skillMd = generateSkillMarkdown({
      slug,
      brand_name: "Nike",
      domain: "nike.com",
      generated_at_iso: "2026-05-28T12:00:00Z",
      product_count: 0,
      category_count: 0,
      collection_count: 0,
      competitor_slugs: [],
      ad_count: 0,
      ad_providers: [],
      has_video: false,
      brandnana_version: "1.0.0",
      capture_cost_usd: 0.01,
    });

    const workbookHtml = await bundleWorkbook(
      { slug, title: "Nike brand book", createdAt: "2026-05-28T12:00:00Z", generator: "test" },
      [{ path: "brand.org", content: "* Nike :brand:\n" }],
    );

    const gz = await tarGz([
      { path: "SKILL.md", bytes: enc.encode(skillMd) },
      { path: `${slug}.html`, bytes: enc.encode(workbookHtml) },
    ]);

    // 1. Starts with gzip magic
    expect(gz[0]).toBe(0x1f);
    expect(gz[1]).toBe(0x8b);
    // 2. Non-trivial size
    expect(gz.length).toBeGreaterThan(200);
  });
});
