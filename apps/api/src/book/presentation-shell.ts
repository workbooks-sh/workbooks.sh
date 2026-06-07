// Self-contained Presentation shell for brandnana brand books.
//
// Renders a 10-slide brand book as a vanilla-JS slide deck inside a single
// .html file. NO build step, NO Svelte runtime, NO external CSS — everything
// inlines into one ~12KB HTML document plus the embedded data.
//
// The data is injected as <script id="book-data" type="application/json">…</script>
// alongside the standard workbook-spec marker, so the file is BOTH a valid
// Workbooks workbook (can be opened in the desktop) AND a viewable standalone
// presentation (can be opened in any browser).
//
// Layout:
//   - 16:9 stage centered in viewport, dark surround
//   - Each slide is a <section>, only one visible at a time
//   - Keyboard: ←/→ ·  j/k ·  space/shift+space ·  Home/End ·  F = fullscreen
//   - Dot navigation bottom of viewport
//   - Slide counter bottom-right
//   - Theme follows the brand's primary palette (light/dark auto-detected)

import type { CuratedBook, SlideKey } from "../agent/curate.js";
import type { InsightSlide } from "@brandnana/schema/analysis-slides";
import type { SeedBrand } from "../agent/seed-brands.js";
import { renderSourceBundleScript } from "./book-bundle.js";

/**
 * Shape of the JSON injected as <script id="book-data">. Pure data, all
 * presentation logic lives in the bundled JS.
 */
export interface BookData {
  spec: {
    slug: string;
    title: string;
    generated_at: string;
    generator: string;
    data_source: "vendor" | "seed" | "mixed";
  };
  brand: {
    name: string;
    domain: string;
    category: string;
    tagline: string;
    description: string;
    logo_svg_url: string;
    /** How the logo was obtained — clearbit / favicon / og-image / etc. */
    logo_source?: string;
    primary_font: string;
    secondary_font: string;
    social: Array<{ network: string; url: string }>;
  };
  palette: Array<{ hex: string; name: string; role: string; note: string }>;
  type_samples: Array<{ family: string; role: string; sample: string }>;
  products: Array<{ name: string; price: number; currency: string; category: string }>;
  ads: Array<{ headline: string; platform: string; cta: string }>;
  competitors: Array<{ name: string; domain: string }>;
  voice_notes: string[];
  /** Auto-derived visual reference assets (wb-tmmw issue 3). */
  extras: {
    homepage_screenshot?: { url: string; source: string; viewport: { width: number; height: number } };
    style_signal?: string;
  };
  timeline: Array<{
    ts: string;
    verb_id: string;
    status: string;
    /** TimelineEvent allows string | number for telemetry-friendliness. */
    duration_ms?: string | number;
    summary?: string;
    error?: string;
  }>;
  curated: {
    cover_headline: string;
    cover_subhead: string;
    slide_order: SlideKey[];
    section_blurbs: Partial<Record<SlideKey, string>>;
    source: "cerebras" | "fallback";
  };
  /**
   * Data-driven slides mapped from the strategist's grounded analysis/*.org
   * (one per :insight: family) — appended after the templated deck so the book
   * argues what the strategist actually found, not just a fixed template
   * (BRANDBOOK-STATUS §3.3). Empty when no analysis was authored.
   */
  insight_slides: InsightSlide[];
}

export function composeBookData(
  brand: SeedBrand,
  curated: CuratedBook,
  opts: {
    slug: string;
    title: string;
    generatedAt: string;
    dataSource: "vendor" | "seed" | "mixed";
    timeline?: BookData["timeline"];
    extras?: BookData["extras"];
    logoSource?: string;
    insightSlides?: InsightSlide[];
  },
): BookData {
  return {
    spec: {
      slug: opts.slug,
      title: opts.title,
      generated_at: opts.generatedAt,
      generator: "brandnana-api",
      data_source: opts.dataSource,
    },
    brand: {
      name: brand.brand_name,
      domain: brand.domain,
      category: brand.category,
      tagline: brand.tagline,
      description: brand.description,
      logo_svg_url: brand.logo_svg_url,
      logo_source: opts.logoSource,
      primary_font: brand.primary_font,
      secondary_font: brand.secondary_font,
      social: brand.social,
    },
    palette: curated.palette_roles.map((r) => {
      const seed = brand.palette.find((c) => c.hex.toLowerCase() === r.hex.toLowerCase());
      return { hex: r.hex, name: seed?.name ?? r.note, role: r.role, note: r.note };
    }),
    type_samples: [
      {
        family: brand.primary_font,
        role: "display / heading",
        sample: brand.brand_name,
      },
      {
        family: brand.secondary_font,
        role: "body / supporting",
        sample: brand.tagline,
      },
    ],
    products: brand.products,
    ads: brand.ads,
    competitors: brand.competitors,
    voice_notes: curated.voice_notes,
    extras: {
      homepage_screenshot: opts.extras?.homepage_screenshot,
      style_signal: opts.extras?.style_signal ?? curated.style_signal,
    },
    timeline: opts.timeline ?? [],
    curated: {
      cover_headline: curated.cover_headline,
      cover_subhead: curated.cover_subhead,
      slide_order: curated.slide_order,
      section_blurbs: curated.section_blurbs,
      source: curated.source,
    },
    insight_slides: opts.insightSlides ?? [],
  };
}

// HTML escape (only needed for static string interp; data is JSON-injected).
function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/**
 * Render the full self-contained .html. Injects:
 *   - data as <script id="book-data" type="application/json">
 *   - workbook-spec marker (Workbooks compatibility)
 *   - source-bundle marker (provided by caller, base64 gzip of .org files)
 */
export function renderPresentation(args: {
  data: BookData;
  /** workbook-spec JSON (Workbooks compatibility marker). */
  workbookSpec: object;
  /** Base64 gzip of the .org source files (for desktop unpacking). */
  sourceBundleBase64: string;
  /** Number of .org files in the bundle — stamped as data-file-count for inspection. */
  sourceFileCount?: number;
}): string {
  const dataJson = JSON.stringify(args.data);
  const specJson = JSON.stringify(args.workbookSpec);
  const title = esc(args.data.spec.title);

  // Font families to preload from Google Fonts (best-effort, fail silently).
  // If the brand's font isn't on Google Fonts the browser will fall back.
  const fonts = Array.from(
    new Set([args.data.brand.primary_font, args.data.brand.secondary_font].filter(Boolean)),
  );
  const fontParam = fonts
    .map((f) => `family=${encodeURIComponent(f).replace(/%20/g, "+")}:wght@400;500;600;700`)
    .join("&");
  const fontHref = fonts.length
    ? `https://fonts.googleapis.com/css2?${fontParam}&display=swap`
    : "";

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
${fontHref ? `<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="${esc(fontHref)}" rel="stylesheet">` : ""}
<style>${SHELL_CSS}</style>
</head>
<body>
<div id="stage-wrap">
  <div id="stage" aria-live="polite"></div>
  <nav id="dots" aria-label="slide navigation"></nav>
  <div id="counter" aria-live="off"></div>
  <div id="chrome">
    <span id="chrome-brand"></span>
    <span class="sep">·</span>
    <span id="chrome-meta"></span>
    <button id="fs-btn" title="fullscreen (F)" aria-label="fullscreen">⛶</button>
  </div>
</div>

<script id="workbook-spec" type="application/json">${specJson}</script>
<script id="book-data" type="application/json">${dataJson}</script>
${renderSourceBundleScript(args.sourceBundleBase64, args.sourceFileCount)}
<script>${SHELL_JS}</script>
</body>
</html>`;
}

// ── Styles ────────────────────────────────────────────────────────────────────
//
// Theme tokens come from the brand's primary/secondary hex applied at runtime
// via CSS custom properties.

const SHELL_CSS = `
:root {
  --bg: #0e0e10;
  --surround: #08080a;
  --stage-bg: #ffffff;
  --fg: #111111;
  --fg-muted: #555555;
  --fg-subtle: #888888;
  --primary: #111111;
  --secondary: #f4f4f4;
  --accent: #0070f3;
  --line: rgba(0,0,0,.10);
  --font-display: ui-serif, Georgia, "Times New Roman", serif;
  --font-body: ui-sans-serif, system-ui, -apple-system, "Helvetica Neue", Arial, sans-serif;
  --stage-w: 1280px;
  --stage-h: 720px;
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: var(--surround); color: #fff; font-family: var(--font-body); height: 100%; overflow: hidden; }
#stage-wrap {
  position: fixed; inset: 0;
  display: grid;
  grid-template-rows: 1fr auto;
  align-items: center; justify-items: center;
  padding: clamp(12px, 3vh, 40px) clamp(12px, 3vw, 60px) 60px;
}
#stage {
  width: min(100%, calc((100vh - 140px) * (16/9)));
  aspect-ratio: 16/9;
  max-width: var(--stage-w);
  background: var(--stage-bg);
  color: var(--fg);
  border-radius: 14px;
  box-shadow: 0 12px 64px -16px rgba(0,0,0,.55), 0 2px 6px rgba(0,0,0,.4);
  position: relative;
  overflow: hidden;
}
#stage section {
  position: absolute; inset: 0;
  padding: clamp(28px, 4.5vh, 60px) clamp(36px, 5vw, 78px);
  display: flex; flex-direction: column;
  opacity: 0; transition: opacity 220ms ease;
  pointer-events: none;
  overflow: hidden;
}
#stage section.active { opacity: 1; pointer-events: auto; }
.eyebrow {
  font-size: 11px; letter-spacing: .18em; text-transform: uppercase;
  color: var(--fg-subtle); margin-bottom: 14px; font-weight: 600;
}
h1, h2 { font-family: var(--font-display); margin: 0; font-weight: 600; color: var(--fg); }
h1 { font-size: clamp(28px, 5vw, 64px); line-height: 1.05; letter-spacing: -0.02em; }
h2 { font-size: clamp(20px, 2.4vw, 32px); line-height: 1.1; margin-bottom: 18px; }
p { color: var(--fg-muted); line-height: 1.55; font-size: clamp(13px, 1.05vw, 16px); margin: 0; }
.subhead { font-size: clamp(16px, 1.5vw, 22px); color: var(--fg-muted); margin-top: 16px; max-width: 50ch; }
.blurb { color: var(--fg-muted); font-size: clamp(13px, 1vw, 16px); margin-bottom: 26px; max-width: 60ch; }

/* data-driven insight slides: grounds render as citation chips */
.grounds { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 22px; }
.ground { font-family: var(--font-mono, monospace); font-size: 11px; color: var(--fg-muted); background: rgba(0,0,0,.04); border: 1px solid var(--line); border-radius: 6px; padding: 3px 8px; }

/* slide-specific layouts */
.cover { justify-content: center; }
.cover .brand-tag { font-size: 12px; letter-spacing: .22em; text-transform: uppercase; color: var(--fg-subtle); margin-bottom: 28px; }
.cover h1 { max-width: 22ch; }
.cover .credit { position: absolute; bottom: 36px; left: 78px; font-size: 12px; color: var(--fg-subtle); letter-spacing: .04em; }

.palette-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 18px; }
.swatch { aspect-ratio: 1.4/1; border-radius: 10px; padding: 14px; display: flex; flex-direction: column; justify-content: flex-end; position: relative; }
.swatch .role { font-size: 10px; letter-spacing: .14em; text-transform: uppercase; opacity: .8; }
.swatch .name { font-size: 14px; font-weight: 600; margin-top: 4px; }
.swatch .hex { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 11px; opacity: .75; }

.type-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 32px; flex: 1; min-height: 0; }
.type-card { padding: 24px; border-radius: 10px; background: rgba(0,0,0,.03); display: flex; flex-direction: column; justify-content: space-between; }
.type-card .role { font-size: 10px; letter-spacing: .14em; text-transform: uppercase; color: var(--fg-subtle); }
.type-card .specimen { font-size: clamp(36px, 5vw, 84px); line-height: 1.05; color: var(--fg); margin: 12px 0; }
.type-card .family { font-size: 13px; color: var(--fg-muted); font-family: ui-monospace, monospace; }

.product-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px; }
.product-card { padding: 14px 16px; background: rgba(0,0,0,.03); border-radius: 10px; display: flex; flex-direction: column; gap: 4px; min-height: 88px; }
.product-card .pname { font-size: 13px; color: var(--fg); font-weight: 500; line-height: 1.3; }
.product-card .pcat { font-size: 10px; letter-spacing: .12em; text-transform: uppercase; color: var(--fg-subtle); }
.product-card .price { font-family: ui-monospace, monospace; font-size: 12px; color: var(--fg-muted); margin-top: auto; }

.ad-list { display: flex; flex-direction: column; gap: 14px; }
.ad-row { padding: 16px 18px; background: rgba(0,0,0,.03); border-radius: 10px; display: grid; grid-template-columns: 36px 1fr auto; gap: 14px; align-items: center; }
.ad-row .badge { width: 36px; height: 36px; border-radius: 8px; background: var(--primary); color: #fff; display: grid; place-items: center; font-size: 11px; font-weight: 700; text-transform: uppercase; font-family: ui-monospace, monospace; }
.ad-row .hl { font-size: 15px; color: var(--fg); line-height: 1.3; }
.ad-row .cta { font-size: 11px; color: var(--fg-subtle); letter-spacing: .12em; text-transform: uppercase; }

.comp-list { display: grid; grid-template-columns: repeat(2, 1fr); gap: 12px; }
.comp-row { padding: 12px 16px; background: rgba(0,0,0,.03); border-radius: 8px; display: flex; justify-content: space-between; align-items: baseline; }
.comp-row .cname { font-size: 14px; color: var(--fg); }
.comp-row .cdomain { font-size: 11px; color: var(--fg-subtle); font-family: ui-monospace, monospace; }

.voice-list { display: flex; flex-direction: column; gap: 14px; max-width: 64ch; }
.voice-quote { font-family: var(--font-display); font-size: clamp(18px, 2vw, 28px); line-height: 1.35; color: var(--fg); border-left: 3px solid var(--accent); padding-left: 18px; }

.social-list { display: flex; gap: 10px; flex-wrap: wrap; }
.social-pill { padding: 8px 14px; border-radius: 999px; border: 1px solid var(--line); font-size: 12px; color: var(--fg); text-decoration: none; transition: background 120ms; }
.social-pill:hover { background: rgba(0,0,0,.04); }

.timeline-list { display: flex; flex-direction: column; gap: 6px; font-family: ui-monospace, monospace; font-size: 12px; }
.timeline-row { display: grid; grid-template-columns: 70px 1fr 80px auto; gap: 12px; align-items: baseline; padding: 4px 0; border-bottom: 1px dashed var(--line); }
.timeline-row .ts { color: var(--fg-subtle); }
.timeline-row .verb { color: var(--fg); }
.timeline-row .status { color: var(--accent); }
.timeline-row .dur { color: var(--fg-muted); }

.identity-grid { display: grid; grid-template-columns: 1fr auto; gap: 32px; align-items: center; height: 100%; }
.identity-grid .info { display: flex; flex-direction: column; gap: 14px; }
.identity-grid .info .label { font-size: 10px; letter-spacing: .14em; text-transform: uppercase; color: var(--fg-subtle); }
.identity-grid .info .value { font-size: 14px; color: var(--fg); }
.identity-grid .info .description { font-size: 15px; color: var(--fg-muted); line-height: 1.5; max-width: 50ch; }
.identity-grid .logo-card { width: 220px; height: 220px; border-radius: 14px; background: var(--secondary); color: var(--primary); display: grid; place-items: center; padding: 28px; border: 1px solid var(--line); overflow: hidden; }
.identity-grid .logo-card img { max-width: 100%; max-height: 100%; object-fit: contain; display: block; }
.identity-grid .logo-card .mark { font-family: var(--font-display); font-size: 36px; font-weight: 700; text-align: center; line-height: 1.1; color: var(--primary); }

/* Homepage slide */
.homepage-grid { display: grid; grid-template-columns: 1.4fr 1fr; gap: 24px; flex: 1; min-height: 0; }
.homepage-screenshot { width: 100%; height: 100%; border-radius: 10px; border: 1px solid var(--line); overflow: hidden; background: var(--secondary); display: flex; align-items: flex-start; justify-content: center; }
.homepage-screenshot img { width: 100%; height: auto; max-height: 100%; object-fit: cover; object-position: top center; display: block; }
.homepage-side { display: flex; flex-direction: column; gap: 18px; min-width: 0; }
.homepage-side .style-signal { font-family: var(--font-display); font-size: clamp(18px, 1.8vw, 24px); line-height: 1.35; color: var(--fg); border-left: 3px solid var(--accent); padding-left: 16px; }
.homepage-side .meta-row { display: flex; flex-direction: column; gap: 4px; font-size: 11px; }
.homepage-side .meta-row .label { color: var(--fg-subtle); letter-spacing: .12em; text-transform: uppercase; }
.homepage-side .meta-row .value { color: var(--fg); font-family: ui-monospace, monospace; word-break: break-all; }

/* nav */
#dots { display: flex; gap: 6px; align-items: center; justify-content: center; padding: 16px 0 0; }
#dots button { width: 8px; height: 8px; border-radius: 50%; border: 0; background: rgba(255,255,255,.22); cursor: pointer; padding: 0; transition: background 120ms, transform 120ms; }
#dots button:hover { background: rgba(255,255,255,.45); transform: scale(1.2); }
#dots button.active { background: rgba(255,255,255,.85); }
#counter { position: fixed; bottom: 18px; right: 22px; font-family: ui-monospace, monospace; font-size: 11px; color: rgba(255,255,255,.55); letter-spacing: .06em; }
#chrome { position: fixed; bottom: 18px; left: 22px; font-size: 11px; color: rgba(255,255,255,.45); letter-spacing: .04em; display: flex; align-items: center; gap: 8px; }
#chrome .sep { opacity: .5; }
#fs-btn { background: none; border: 0; color: rgba(255,255,255,.4); font-size: 14px; cursor: pointer; padding: 2px 6px; margin-left: 6px; transition: color 120ms; }
#fs-btn:hover { color: rgba(255,255,255,.9); }

/* full-bleed cover variant */
.cover.full-bleed { background: var(--primary); color: var(--secondary); }
.cover.full-bleed h1, .cover.full-bleed .brand-tag, .cover.full-bleed .subhead { color: var(--secondary); }
.cover.full-bleed .brand-tag { opacity: .7; }
.cover.full-bleed .subhead { opacity: .85; }
.cover.full-bleed .credit { color: var(--secondary); opacity: .55; }

@media (max-width: 700px) {
  #stage-wrap { padding: 8px 8px 60px; }
  #stage { border-radius: 8px; }
  .palette-grid { grid-template-columns: repeat(2, 1fr); }
  .type-grid, .comp-list, .product-grid { grid-template-columns: 1fr; }
}
`;

// ── Runtime JS ────────────────────────────────────────────────────────────────

const SHELL_JS = `
(function() {
  var data = JSON.parse(document.getElementById('book-data').textContent);
  var stage = document.getElementById('stage');
  var dotsEl = document.getElementById('dots');
  var counterEl = document.getElementById('counter');
  var chromeBrand = document.getElementById('chrome-brand');
  var chromeMeta = document.getElementById('chrome-meta');
  var fsBtn = document.getElementById('fs-btn');

  // Theme: apply brand palette as CSS variables.
  var root = document.documentElement;
  if (data.palette && data.palette.length) {
    var primary = data.palette.find(function(c){return c.role && c.role.indexOf('primary') === 0}) || data.palette[0];
    var secondary = data.palette.find(function(c){return c.role && c.role.indexOf('secondary') === 0}) || data.palette[1] || { hex: '#f4f4f4' };
    var accent = data.palette.find(function(c){return /accent|highlight/.test(c.role||'')}) || data.palette[2] || primary;
    root.style.setProperty('--primary', primary.hex);
    root.style.setProperty('--secondary', secondary.hex);
    root.style.setProperty('--accent', accent.hex);
  }
  if (data.brand.primary_font) {
    root.style.setProperty('--font-display', '"' + data.brand.primary_font + '", ui-serif, Georgia, serif');
  }
  if (data.brand.secondary_font) {
    root.style.setProperty('--font-body', '"' + data.brand.secondary_font + '", ui-sans-serif, system-ui, sans-serif');
  }

  chromeBrand.textContent = data.brand.name + ' · brand book';
  chromeMeta.textContent = data.spec.generated_at.slice(0, 10) + ' · ' + (data.curated.source === 'cerebras' ? 'curated by glm-4.7' : 'fallback narrative');

  function esc(s) { return String(s == null ? '' : s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

  function slideCover() {
    var c = data.curated;
    return '<section class="cover full-bleed" data-slide="cover">' +
      '<div class="brand-tag">' + esc(data.brand.name) + ' · ' + esc(data.brand.category) + '</div>' +
      '<h1>' + esc(c.cover_headline) + '</h1>' +
      '<div class="subhead">' + esc(c.cover_subhead) + '</div>' +
      '<div class="credit">brandnana · captured ' + esc(data.spec.generated_at.slice(0,10)) + '</div>' +
      '</section>';
  }
  function slideIdentity() {
    var initials = data.brand.name.split(' ').map(function(w){return w[0]}).join('').slice(0,3);
    var logoHtml = data.brand.logo_svg_url
      ? '<img src="' + esc(data.brand.logo_svg_url) + '" alt="' + esc(data.brand.name) + ' logo" onerror="this.style.display=\\'none\\'; this.nextElementSibling.style.display=\\'block\\'">'
      : '';
    return '<section data-slide="identity">' +
      '<div class="eyebrow">01 · identity</div>' +
      '<h2>' + esc(data.brand.name) + '</h2>' +
      '<div class="blurb">' + esc(data.curated.section_blurbs.identity || '') + '</div>' +
      '<div class="identity-grid">' +
        '<div class="info">' +
          '<div><div class="label">domain</div><div class="value">' + esc(data.brand.domain) + '</div></div>' +
          '<div><div class="label">category</div><div class="value">' + esc(data.brand.category) + '</div></div>' +
          '<div><div class="label">tagline</div><div class="value">' + esc(data.brand.tagline) + '</div></div>' +
          '<div class="description">' + esc(data.brand.description) + '</div>' +
        '</div>' +
        '<div class="logo-card">' +
          logoHtml +
          '<div class="mark"' + (logoHtml ? ' style="display:none"' : '') + '>' + esc(initials) + '</div>' +
        '</div>' +
      '</div>' +
      '</section>';
  }
  function slidePalette() {
    return '<section data-slide="palette">' +
      '<div class="eyebrow">02 · palette</div>' +
      '<h2>Color system</h2>' +
      '<div class="blurb">' + esc(data.curated.section_blurbs.palette || '') + '</div>' +
      '<div class="palette-grid">' +
      data.palette.map(function(c){
        var lum = parseInt(c.hex.replace('#','').slice(0,2),16)*0.299 + parseInt(c.hex.replace('#','').slice(2,4),16)*0.587 + parseInt(c.hex.replace('#','').slice(4,6),16)*0.114;
        var fg = lum > 130 ? '#111' : '#fff';
        return '<div class="swatch" style="background:' + esc(c.hex) + ';color:' + fg + '">' +
          '<div class="role">' + esc(c.role) + '</div>' +
          '<div class="name">' + esc(c.name) + '</div>' +
          '<div class="hex">' + esc(c.hex) + '</div>' +
        '</div>';
      }).join('') +
      '</div></section>';
  }
  function slideType() {
    return '<section data-slide="type">' +
      '<div class="eyebrow">03 · typography</div>' +
      '<h2>Typographic system</h2>' +
      '<div class="blurb">' + esc(data.curated.section_blurbs.type || '') + '</div>' +
      '<div class="type-grid">' +
      data.type_samples.map(function(t){
        return '<div class="type-card">' +
          '<div class="role">' + esc(t.role) + '</div>' +
          '<div class="specimen" style="font-family: \\'' + esc(t.family) + '\\', ui-serif, serif">' + esc(t.sample) + '</div>' +
          '<div class="family">' + esc(t.family) + '</div>' +
        '</div>';
      }).join('') +
      '</div></section>';
  }
  function slideVoice() {
    return '<section data-slide="voice">' +
      '<div class="eyebrow">04 · voice</div>' +
      '<h2>How the brand sounds</h2>' +
      '<div class="blurb">' + esc(data.curated.section_blurbs.voice || '') + '</div>' +
      '<div class="voice-list">' +
      data.voice_notes.map(function(v){
        return '<div class="voice-quote">' + esc(v) + '</div>';
      }).join('') +
      '</div></section>';
  }
  function slideCatalog() {
    if (!data.products.length) {
      return '<section data-slide="catalog">' +
        '<div class="eyebrow">05 · catalog</div>' +
        '<h2>Catalog</h2>' +
        '<div class="blurb">No product samples available yet — wire up a vendor key.</div>' +
        '</section>';
    }
    return '<section data-slide="catalog">' +
      '<div class="eyebrow">05 · catalog</div>' +
      '<h2>What the brand sells</h2>' +
      '<div class="blurb">' + esc(data.curated.section_blurbs.catalog || '') + '</div>' +
      '<div class="product-grid">' +
      data.products.slice(0, 6).map(function(p){
        var price = p.price === 0 ? 'free' : '$' + p.price.toFixed(p.price % 1 ? 2 : 0);
        return '<div class="product-card">' +
          '<div class="pname">' + esc(p.name) + '</div>' +
          '<div class="pcat">' + esc(p.category) + '</div>' +
          '<div class="price">' + price + '</div>' +
        '</div>';
      }).join('') +
      '</div></section>';
  }
  function slideAds() {
    return '<section data-slide="ads">' +
      '<div class="eyebrow">06 · campaigns</div>' +
      '<h2>How the brand talks</h2>' +
      '<div class="blurb">' + esc(data.curated.section_blurbs.ads || '') + '</div>' +
      '<div class="ad-list">' +
      data.ads.slice(0, 5).map(function(a){
        return '<div class="ad-row">' +
          '<div class="badge">' + esc((a.platform||'?')[0]) + '</div>' +
          '<div class="hl">"' + esc(a.headline) + '"</div>' +
          '<div class="cta">' + esc(a.platform) + ' · ' + esc(a.cta) + '</div>' +
        '</div>';
      }).join('') +
      '</div></section>';
  }
  function slideCompetitors() {
    return '<section data-slide="competitors">' +
      '<div class="eyebrow">07 · landscape</div>' +
      '<h2>Where it stands</h2>' +
      '<div class="blurb">' + esc(data.curated.section_blurbs.competitors || '') + '</div>' +
      '<div class="comp-list">' +
      data.competitors.map(function(c){
        return '<div class="comp-row"><span class="cname">' + esc(c.name) + '</span><span class="cdomain">' + esc(c.domain) + '</span></div>';
      }).join('') +
      '</div></section>';
  }
  function slideSocial() {
    return '<section data-slide="social">' +
      '<div class="eyebrow">08 · social</div>' +
      '<h2>Where it shows up</h2>' +
      '<div class="blurb">' + esc(data.curated.section_blurbs.social || '') + '</div>' +
      '<div class="social-list">' +
      data.brand.social.map(function(s){
        return '<a class="social-pill" href="' + esc(s.url) + '" target="_blank" rel="noopener">' + esc(s.network) + '</a>';
      }).join('') +
      '</div></section>';
  }
  function slideTimeline() {
    if (!data.timeline.length) {
      return '<section data-slide="timeline">' +
        '<div class="eyebrow">09 · capture trace</div>' +
        '<h2>How this was captured</h2>' +
        '<div class="blurb">Trace not recorded for this book.</div>' +
        '</section>';
    }
    return '<section data-slide="timeline">' +
      '<div class="eyebrow">09 · capture trace</div>' +
      '<h2>How this was captured</h2>' +
      '<div class="blurb">' + esc(data.curated.section_blurbs.timeline || '') + '</div>' +
      '<div class="timeline-list">' +
      data.timeline.map(function(t){
        return '<div class="timeline-row">' +
          '<span class="ts">' + esc(t.ts.slice(11,19)) + '</span>' +
          '<span class="verb">' + esc(t.verb_id) + '</span>' +
          '<span class="status">' + esc(t.status) + '</span>' +
          '<span class="dur">' + esc((t.duration_ms||0) + 'ms') + '</span>' +
        '</div>';
      }).join('') +
      '</div></section>';
  }

  function slideHomepage() {
    var shot = data.extras?.homepage_screenshot;
    var signal = data.extras?.style_signal;
    var url = 'https://' + data.brand.domain + '/';
    return '<section data-slide="homepage">' +
      '<div class="eyebrow">02 · homepage</div>' +
      '<h2>How the site presents itself</h2>' +
      '<div class="blurb">' + esc(data.curated.section_blurbs.homepage || '') + '</div>' +
      '<div class="homepage-grid">' +
        '<div class="homepage-screenshot">' +
          (shot
            ? '<img src="' + esc(shot.url) + '" alt="' + esc(data.brand.name) + ' homepage" loading="lazy">'
            : '<div style="color:#888;font-size:13px;padding:32px;text-align:center">No screenshot captured.</div>') +
        '</div>' +
        '<div class="homepage-side">' +
          (signal ? '<div class="style-signal">' + esc(signal) + '</div>' : '') +
          '<div class="meta-row"><div class="label">url</div><div class="value">' + esc(url) + '</div></div>' +
          (shot ? '<div class="meta-row"><div class="label">screenshot via</div><div class="value">' + esc(shot.source) + ' · ' + shot.viewport.width + '×' + shot.viewport.height + '</div></div>' : '') +
        '</div>' +
      '</div>' +
      '</section>';
  }

  // Generic data-driven slide: one per grounded :insight: from analysis/*.org.
  // The family (type) is the eyebrow, the headline the argument, the prose the
  // body, and the GROUNDS render as citation chips — proof the claim is grounded.
  function slideInsight(s) {
    var grounds = (s.grounds || []).map(function(g){
      return '<span class="ground">' + esc(g) + '</span>';
    }).join('');
    return '<section data-slide="' + esc(s.key) + '">' +
      '<div class="eyebrow">' + esc(s.type || 'insight') + '</div>' +
      '<h2>' + esc(s.title || '') + '</h2>' +
      '<div class="blurb">' + esc(s.body || '') + '</div>' +
      (grounds ? '<div class="grounds">' + grounds + '</div>' : '') +
      '</section>';
  }

  var BUILDERS = {
    cover: slideCover, identity: slideIdentity, homepage: slideHomepage, palette: slidePalette,
    type: slideType, voice: slideVoice, catalog: slideCatalog, ads: slideAds,
    competitors: slideCompetitors, social: slideSocial, timeline: slideTimeline,
  };

  var order = (data.curated.slide_order || ['cover']).filter(function(k){return BUILDERS[k]});
  if (!order.length) order = ['cover'];

  var html = order.map(function(k){return BUILDERS[k]()}).join('');
  // Append the data-driven insight slides after the templated deck.
  var insightSlides = data.insight_slides || [];
  for (var n = 0; n < insightSlides.length; n++) {
    order.push(insightSlides[n].key);
    html += slideInsight(insightSlides[n]);
  }
  stage.innerHTML = html;
  var slides = stage.querySelectorAll('section');
  var idx = 0;

  function render() {
    for (var i = 0; i < slides.length; i++) {
      slides[i].classList.toggle('active', i === idx);
    }
    var buttons = dotsEl.querySelectorAll('button');
    for (var j = 0; j < buttons.length; j++) buttons[j].classList.toggle('active', j === idx);
    counterEl.textContent = (idx + 1) + ' / ' + slides.length;
    location.hash = '#' + order[idx];
  }
  function go(n) {
    idx = Math.max(0, Math.min(slides.length - 1, n));
    render();
  }

  // dots
  for (var k = 0; k < order.length; k++) {
    (function(i){
      var b = document.createElement('button');
      b.setAttribute('aria-label', 'go to slide ' + (i+1));
      b.addEventListener('click', function(){ go(i); });
      dotsEl.appendChild(b);
    })(k);
  }

  // initial slide from hash (?
  var startHash = location.hash.replace('#','');
  var startIdx = order.indexOf(startHash);
  if (startIdx >= 0) idx = startIdx;

  document.addEventListener('keydown', function(e){
    if (e.key === 'ArrowRight' || e.key === 'PageDown' || e.key === ' ' || e.key === 'l' || e.key === 'k') { go(idx + 1); e.preventDefault(); }
    else if (e.key === 'ArrowLeft' || e.key === 'PageUp' || e.key === 'h' || e.key === 'j') { go(idx - 1); e.preventDefault(); }
    else if (e.key === 'Home') { go(0); e.preventDefault(); }
    else if (e.key === 'End') { go(slides.length - 1); e.preventDefault(); }
    else if (e.key === 'f' || e.key === 'F') { document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen(); }
  });
  fsBtn.addEventListener('click', function(){ document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen(); });
  // swipe
  var sx = 0;
  stage.addEventListener('touchstart', function(e){ sx = e.touches[0].clientX; }, { passive: true });
  stage.addEventListener('touchend', function(e){ var dx = e.changedTouches[0].clientX - sx; if (Math.abs(dx) > 40) go(idx + (dx < 0 ? 1 : -1)); });

  render();
})();
`;
