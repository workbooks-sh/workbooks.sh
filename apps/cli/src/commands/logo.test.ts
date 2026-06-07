// Unit tests for brandnana logo command helpers.
// Run with: bun test src/commands/logo.test.ts

import { describe, expect, it } from "bun:test";
import {
  computeConfidence,
  isAppIconCandidate,
  isFaviconReject,
  probeHomepageFromHtml,
} from "./logo.js";
import { deriveSvgTags } from "./logo-tags.js";

// ── SVG structural tagging ───────────────────────────────────────────────────

describe("deriveSvgTags", () => {
  it("transparent monochrome wide wordmark", () => {
    const svg = '<svg viewBox="0 0 300 60"><path fill="#111111" d="M0 0h10"/></svg>';
    const t = deriveSvgTags(svg);
    expect(t.transparent).toBe(true);
    expect(t.monochrome).toBe(true);
    expect(t.has_wordmark).toBe(true);
    expect(t.kind).toBe("wordmark");
    expect(t.via).toBe("svg-source");
  });

  it("multi-colour square symbol with a background fill is not transparent", () => {
    const svg =
      '<svg viewBox="0 0 100 100"><rect width="100" height="100" fill="#ffffff"/>' +
      '<circle fill="#e4002b" cx="50" cy="50" r="20"/><path stroke="#1a73e8" d="M0 0"/></svg>';
    const t = deriveSvgTags(svg);
    expect(t.transparent).toBe(false);
    expect(t.monochrome).toBe(false);
    expect(t.kind === "symbol" || t.kind === "icon").toBe(true);
    expect(t.palette).toContain("#e4002b");
  });
});

// ── Test 1: synthetic HTML with <img src="brand-logo.svg"> ──────────────────

describe("probeHomepageFromHtml — logo img", () => {
  it("returns the SVG img when src contains 'logo'", () => {
    const html = `
      <html>
        <head><title>BrandCo</title></head>
        <body>
          <header>
            <img src="/static/brand-logo.svg" alt="BrandCo Logo" width="240" height="60" />
          </header>
        </body>
      </html>
    `;
    const results = probeHomepageFromHtml("https://brandco.com", html);
    expect(results.length).toBeGreaterThanOrEqual(1);
    const logoHit = results.find((r) => r.url.includes("brand-logo.svg"));
    expect(logoHit).toBeDefined();
    expect(logoHit?.url).toBe("https://brandco.com/static/brand-logo.svg");
    expect(logoHit?.note).toContain("homepage <img>");
  });

  it("returns an img when alt contains 'wordmark'", () => {
    const html = `
      <html><body>
        <img src="/images/lockup.png" alt="BrandCo Wordmark" />
      </body></html>
    `;
    const results = probeHomepageFromHtml("https://brandco.com", html);
    const hit = results.find((r) => r.url.includes("lockup.png"));
    expect(hit).toBeDefined();
  });
});

// ── Test 2: synthetic HTML with only favicon → empty candidates + rejected ──

describe("probeHomepageFromHtml — favicon only", () => {
  it("does not return favicon-style paths from <img> scraping", () => {
    const html = `
      <html>
        <head>
          <link rel="shortcut icon" href="/favicon.ico" />
          <link rel="apple-touch-icon" href="/apple-touch-icon.png" />
        </head>
        <body>
          <img src="/apple-touch-icon.png" alt="App Icon" />
        </body>
      </html>
    `;
    // Homepage scraper looks for 'logo'/'brand'/'wordmark' in src or alt.
    // None of these match that pattern, so results should be empty.
    const results = probeHomepageFromHtml("https://brandco.com", html);
    expect(results.length).toBe(0);
  });

  it("svg <link rel=icon> IS returned (SVG icon links pass through — we validate aspect later)", () => {
    const html = `
      <html>
        <head>
          <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
        </head>
      </html>
    `;
    const results = probeHomepageFromHtml("https://brandco.com", html);
    // SVG icon links are returned by the scraper — aspect ratio / favicon-URL
    // rejection happens downstream in buildLogoResult.
    const svgIconHit = results.find((r) => r.url.includes("favicon.svg"));
    expect(svgIconHit).toBeDefined();
  });
});

// ── Test 3: aspect_ratio filter correctly classifies app icons ──────────────

describe("isAppIconCandidate", () => {
  it("rejects a square apple-touch-icon URL with aspect 1.0", () => {
    expect(isAppIconCandidate("https://brand.com/apple-touch-icon.png", 1.0)).toBe(true);
  });

  it("rejects a square favicon URL with aspect 1.0", () => {
    expect(isAppIconCandidate("https://brand.com/favicon.png", 1.0)).toBe(true);
  });

  it("rejects a square icon-192 URL with aspect 1.0", () => {
    expect(isAppIconCandidate("https://brand.com/icon-192.png", 1.0)).toBe(true);
  });

  it("does not reject a wide-aspect URL with aspect 4.0, even if named logo", () => {
    expect(isAppIconCandidate("https://brand.com/logo.svg", 4.0)).toBe(false);
  });

  it("does not reject a non-favicon URL even if square (pure logomark may be square)", () => {
    // A square image that is NOT from a favicon URL is kept for human review.
    expect(isAppIconCandidate("https://brand.com/logomark.svg", 1.0)).toBe(false);
  });

  it("does not reject when aspect_ratio is undefined", () => {
    expect(isAppIconCandidate("https://brand.com/apple-touch-icon.png", undefined)).toBe(false);
  });

  it("rejects near-square (aspect 1.1) favicon URL", () => {
    expect(isAppIconCandidate("https://brand.com/apple-touch-icon-precomposed.png", 1.1)).toBe(true);
  });

  it("does not reject aspect 0.84 (below threshold)", () => {
    expect(isAppIconCandidate("https://brand.com/apple-touch-icon.png", 0.84)).toBe(false);
  });

  it("does not reject aspect 1.19 (above threshold)", () => {
    expect(isAppIconCandidate("https://brand.com/apple-touch-icon.png", 1.19)).toBe(false);
  });
});

// ── Test 3b: favicon-URL rejection (aspect-independent) ─────────────────────

describe("isFaviconReject", () => {
  it("rejects a dimensionless favicon.svg (the tecovas regression)", () => {
    // <link rel=icon type=svg> ships no width/height → aspectRatio undefined.
    // The aspect-ratio-only guard let this through; isFaviconReject must not.
    expect(isFaviconReject("https://tecovas.com/favicon.svg", undefined)).toBe(true);
  });

  it("rejects a square favicon regardless of dimensions", () => {
    expect(isFaviconReject("https://brand.com/favicon.png", 1.0)).toBe(true);
    expect(isFaviconReject("https://brand.com/apple-touch-icon.png", 1.1)).toBe(true);
    expect(isFaviconReject("https://brand.com/icon-192.png", undefined)).toBe(true);
  });

  it("keeps a favicon-named asset ONLY when it is a confirmed wide wordmark", () => {
    // A favicon-named file with a measured wide aspect (>= 2.5) is a real lockup.
    expect(isFaviconReject("https://brand.com/favicon-wordmark.svg", 4.0)).toBe(false);
  });

  it("does not reject a non-favicon URL (even dimensionless)", () => {
    expect(isFaviconReject("https://brand.com/logo.svg", undefined)).toBe(false);
    expect(isFaviconReject("https://brand.com/wordmark.png", 1.0)).toBe(false);
  });
});

// ── Test 4: confidence scoring ───────────────────────────────────────────────

describe("computeConfidence", () => {
  it("homepage SVG wide-aspect ≥ 200px scores 0.88", () => {
    const score = computeConfidence({
      sourceTier: 1,
      format: "svg",
      aspectRatio: 4.0,
      width: 240,
    });
    // 0.48 + 0.30 + 0.05 + 0.05 = 0.88
    expect(score).toBeCloseTo(0.88, 10);
  });

  it("official sources outrank a clean Wikipedia wordmark", () => {
    const wikipedia = computeConfidence({
      sourceTier: 2,
      format: "svg",
      aspectRatio: 3.5,
      width: 240,
      svgConfirmed: true,
    });
    // 0.20 + 0.30 + 0.05 + 0.05 + 0.05 = 0.65
    expect(wikipedia).toBeCloseTo(0.65, 10);
    // even a plain square logo.dev SVG beats the Wikipedia wordmark
    const logoDevSquare = computeConfidence({ sourceTier: 4, format: "svg", svgConfirmed: true });
    // 0.42 + 0.30 + 0.05 = 0.77
    expect(logoDevSquare).toBeCloseTo(0.77, 10);
    expect(logoDevSquare).toBeGreaterThan(wikipedia);
  });

  it("simpleicons SVG scores 0.35 (no aspect info)", () => {
    const score = computeConfidence({
      sourceTier: 5,
      format: "svg",
    });
    // 0.05 + 0.30 = 0.35
    expect(score).toBe(0.35);
  });

  it("caps at 1.0", () => {
    const score = computeConfidence({
      sourceTier: 1,
      format: "svg",
      aspectRatio: 3.0,
      width: 500,
      svgConfirmed: true,
    });
    expect(score).toBeLessThanOrEqual(1.0);
  });

  it("logo.dev PNG no-aspect scores 0.57", () => {
    const score = computeConfidence({
      sourceTier: 4,
      format: "png",
    });
    // 0.42 + 0.15 = 0.57
    expect(score).toBeCloseTo(0.57, 10);
  });
});
