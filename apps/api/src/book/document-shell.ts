// Document renderer — long-form scrollable workbook. Sibling of
// presentation-shell.ts. Same workbook markers + same source-bundle marker
// so it's a valid Workbooks workbook AND can be opened standalone in any
// browser as a print-friendly research dossier.

import { renderSourceBundleScript } from "./book-bundle.js";

export interface DocumentBlock {
  /** Body text (may include simple inline formatting like **bold** and *italic*). */
  body?: string;
  /** Pre-uploaded image URL to inline at this point. */
  image_url?: string;
  /** Optional caption under the image. */
  image_caption?: string;
  /** Structured data widget the renderer knows how to lay out. */
  data?:
    | { kind: "palette"; payload: Array<{ hex: string; name?: string; role?: string }> }
    | { kind: "products"; payload: Array<{ name: string; price?: number; currency?: string; category?: string }> }
    | { kind: "ads"; payload: Array<{ headline: string; platform?: string; cta?: string }> }
    | { kind: "competitors"; payload: Array<{ name: string; domain: string; note?: string }> }
    | { kind: "stat"; payload: { value: string; label: string } }
    | { kind: "quote"; payload: { quote: string; attribution?: string } }
    | { kind: "timeline"; payload: Array<{ ts: string; verb_id: string; status: string; summary?: string }> }
    | { kind: "table"; payload: { headers: string[]; rows: string[][] } };
}

export interface DocumentSection {
  title: string;
  blocks: DocumentBlock[];
  /** Anchor slug for in-doc navigation. Auto-derived from title if absent. */
  anchor?: string;
}

export interface DocumentData {
  spec: {
    slug: string;
    title: string;
    subtitle?: string;
    generated_at: string;
    domains?: string[];
  };
  /** Optional hero image at the top. */
  hero?: { image_url?: string; eyebrow?: string };
  /** Author block (e.g. "brandnana · 2026-05-29"). */
  byline?: string;
  /** Brand palette to theme the doc with (primary→accent CSS vars). */
  palette?: Array<{ hex: string; name?: string }>;
  /** Primary + secondary font families to apply (loaded via Google Fonts if available). */
  primary_font?: string;
  secondary_font?: string;
  sections: DocumentSection[];
  /** Free-form notes (e.g. verb-trace) appended at the end as small print. */
  endnotes?: string[];
}

function esc(s: string): string {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function slugify(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

/** Minimal inline-markdown: **bold**, *italic*, `code`, [text](url). */
function inlineMd(s: string): string {
  return esc(s)
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/\*(.+?)\*/g, "<em>$1</em>")
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
}

function bodyToHtml(text: string): string {
  // Split into paragraphs by blank lines; convert leading "- " lines to a list.
  const parts = text.split(/\n{2,}/);
  return parts.map((para) => {
    const lines = para.split("\n");
    if (lines.every((l) => /^\s*[-*]\s+/.test(l))) {
      const items = lines.map((l) => `<li>${inlineMd(l.replace(/^\s*[-*]\s+/, ""))}</li>`).join("");
      return `<ul>${items}</ul>`;
    }
    return `<p>${lines.map((l) => inlineMd(l)).join("<br>")}</p>`;
  }).join("\n");
}

import { pickThemeColors } from "../agent/contrast.js";

function ensureArray<T>(v: unknown): T[] { return Array.isArray(v) ? (v as T[]) : []; }

function renderDataWidget(d: NonNullable<DocumentBlock["data"]>): string {
  switch (d.kind) {
    case "palette":
      return `<div class="widget palette">${ensureArray<{ hex: string; name?: string; role?: string }>(d.payload).slice(0, 12).map((c) => {
        const lum = parseInt(c.hex.replace("#", "").slice(0, 2), 16) * 0.299 + parseInt(c.hex.replace("#", "").slice(2, 4), 16) * 0.587 + parseInt(c.hex.replace("#", "").slice(4, 6), 16) * 0.114;
        const fg = lum > 140 ? "#111" : "#fff";
        return `<div class="palette-chip" style="background:${esc(c.hex)};color:${fg}">
          ${c.role ? `<div class="role">${esc(c.role)}</div>` : ""}
          ${c.name ? `<div class="name">${esc(c.name)}</div>` : ""}
          <div class="hex">${esc(c.hex)}</div>
        </div>`;
      }).join("")}</div>`;
    case "products":
      return `<div class="widget product-grid">${ensureArray<any>(d.payload).slice(0, 12).map((p) => `
        <div class="product-card">
          <div class="pname">${esc(p.name)}</div>
          <div class="pcat">${esc(p.category ?? "")}</div>
          <div class="price">${typeof p.price === "number" ? (p.price === 0 ? "free" : "$" + p.price.toFixed(p.price % 1 ? 2 : 0)) : ""}</div>
        </div>`).join("")}</div>`;
    case "ads":
      return `<div class="widget ad-list">${ensureArray<any>(d.payload).slice(0, 8).map((a) => `
        <div class="ad-row">
          <div class="badge">${esc((a.platform || "?")[0].toUpperCase())}</div>
          <div class="hl">"${esc(a.headline)}"</div>
          <div class="cta">${esc(a.platform ?? "")} ${a.cta ? "· " + esc(a.cta) : ""}</div>
        </div>`).join("")}</div>`;
    case "competitors":
      return `<div class="widget comp-grid">${ensureArray<any>(d.payload).slice(0, 8).map((c) => `
        <div class="comp-row"><span class="cname">${esc(c.name)}</span><span class="cdomain">${esc(c.domain)}</span>${c.note ? `<span class="cnote">${esc(c.note)}</span>` : ""}</div>`).join("")}</div>`;
    case "stat":
      return `<div class="widget stat-block"><div class="stat-value">${esc((d.payload as any)?.value ?? "")}</div><div class="stat-label">${esc((d.payload as any)?.label ?? "")}</div></div>`;
    case "quote":
      return `<blockquote class="widget pull-quote">${esc((d.payload as any)?.quote ?? "")}${(d.payload as any)?.attribution ? `<cite>— ${esc((d.payload as any).attribution)}</cite>` : ""}</blockquote>`;
    case "timeline":
      return `<div class="widget timeline">${ensureArray<any>(d.payload).map((t) => `<div class="t-row"><span class="t-verb">${esc(t.verb_id ?? "")}</span><span class="t-status">${esc(t.status ?? "")}</span><span class="t-summary">${esc(t.summary ?? "")}</span></div>`).join("")}</div>`;
    case "table": {
      const p = (d.payload as any) ?? {};
      const headers = ensureArray<string>(p.headers);
      const rows = ensureArray<string[]>(p.rows);
      return `<table class="widget data-table">
        <thead><tr>${headers.map((h) => `<th>${esc(h)}</th>`).join("")}</tr></thead>
        <tbody>${rows.map((row) => `<tr>${ensureArray<string>(row).map((cell) => `<td>${esc(cell)}</td>`).join("")}</tr>`).join("")}</tbody>
      </table>`;
    }
  }
}

export function renderDocument(args: {
  data: DocumentData;
  workbookSpec: object;
  sourceBundleBase64: string;
  /** Number of .org files in the bundle — stamped as data-file-count for inspection. */
  sourceFileCount?: number;
}): string {
  const { data } = args;
  const palette = data.palette ?? [];
  // Contrast-aware theme picking — see agent/contrast.ts. Without this,
  // a brand like Vercel (most-scraped color = #ffffff) renders headings
  // white-on-white.
  const theme = pickThemeColors(palette);
  const primary = theme.primary;
  const secondary = theme.secondary;
  const accent = theme.accent;
  const displayFont = data.primary_font || "Optima, Cormorant Garamond, Georgia, serif";
  const bodyFont = data.secondary_font || "Inter, ui-sans-serif, system-ui, sans-serif";

  // Font loading via Google Fonts (best-effort; falls back if not available).
  const fontFamilies = [data.primary_font, data.secondary_font]
    .filter((f): f is string => !!f)
    .map((f) => `family=${encodeURIComponent(f).replace(/%20/g, "+")}:wght@300;400;500;600;700`)
    .join("&");
  const fontHref = fontFamilies ? `https://fonts.googleapis.com/css2?${fontFamilies}&display=swap` : "";

  const toc = data.sections.map((s, i) => {
    const anchor = s.anchor ?? slugify(s.title);
    return `<li><a href="#${esc(anchor)}">${String(i + 1).padStart(2, "0")}. ${esc(s.title)}</a></li>`;
  }).join("");

  const sectionsHtml = data.sections.map((s, i) => {
    const anchor = s.anchor ?? slugify(s.title);
    const blocks = s.blocks.map((b) => {
      const parts: string[] = [];
      if (b.body) parts.push(bodyToHtml(b.body));
      if (b.image_url) {
        parts.push(`<figure class="inline-image">
          <img src="${esc(b.image_url)}" alt="${esc(b.image_caption ?? s.title)}" loading="lazy">
          ${b.image_caption ? `<figcaption>${esc(b.image_caption)}</figcaption>` : ""}
        </figure>`);
      }
      if (b.data) parts.push(renderDataWidget(b.data));
      return parts.join("\n");
    }).join("\n");
    return `<section id="${esc(anchor)}" class="doc-section">
      <div class="section-num">${String(i + 1).padStart(2, "0")}</div>
      <h2>${esc(s.title)}</h2>
      ${blocks}
    </section>`;
  }).join("\n");

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(data.spec.title)}</title>
${fontHref ? `<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link href="${esc(fontHref)}" rel="stylesheet">` : ""}
<style>${DOC_CSS}</style>
<style>
  :root {
    --primary: ${esc(primary)};
    --secondary: ${esc(secondary)};
    --accent: ${esc(accent)};
    --font-display: "${esc(displayFont.split(",")[0]!.trim())}", serif;
    --font-body: "${esc(bodyFont.split(",")[0]!.trim())}", system-ui, sans-serif;
  }
</style>
</head>
<body>
<article class="doc">
  <header class="doc-header">
    ${data.hero?.eyebrow ? `<div class="eyebrow">${esc(data.hero.eyebrow)}</div>` : ""}
    <h1>${esc(data.spec.title)}</h1>
    ${data.spec.subtitle ? `<p class="subtitle">${esc(data.spec.subtitle)}</p>` : ""}
    ${data.byline ? `<div class="byline">${esc(data.byline)}</div>` : ""}
    ${data.hero?.image_url ? `<figure class="hero-image"><img src="${esc(data.hero.image_url)}" alt="${esc(data.spec.title)}" loading="eager"></figure>` : ""}
  </header>

  <nav class="toc">
    <div class="toc-label">Contents</div>
    <ol>${toc}</ol>
  </nav>

  <main>${sectionsHtml}</main>

  ${data.endnotes?.length ? `<aside class="endnotes">
    <h3>Notes</h3>
    <ul>${data.endnotes.map((n) => `<li>${inlineMd(n)}</li>`).join("")}</ul>
  </aside>` : ""}

  <footer class="doc-footer">
    Generated by brandnana · ${esc(data.spec.generated_at.slice(0, 10))}${data.spec.domains?.length ? ` · ${esc(data.spec.domains.join(", "))}` : ""}
  </footer>
</article>

<script id="workbook-spec" type="application/json">${JSON.stringify(args.workbookSpec)}</script>
<script id="document-data" type="application/json">${JSON.stringify(data)}</script>
${renderSourceBundleScript(args.sourceBundleBase64, args.sourceFileCount)}
</body>
</html>`;
}

// ── Styles ───────────────────────────────────────────────────────────────────

const DOC_CSS = `
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: #fcfcfa; color: #181818; font-family: var(--font-body); font-size: 16px; line-height: 1.6; }
.doc { max-width: 760px; margin: 0 auto; padding: clamp(32px, 6vw, 80px) clamp(20px, 5vw, 56px); }

.doc-header { margin-bottom: 56px; padding-bottom: 32px; border-bottom: 2px solid var(--primary); }
.eyebrow { font-size: 11px; letter-spacing: .22em; text-transform: uppercase; color: var(--accent); margin-bottom: 16px; font-weight: 600; }
.doc-header h1 { font-family: var(--font-display); font-size: clamp(36px, 6vw, 64px); line-height: 1.05; letter-spacing: -0.015em; margin: 0; font-weight: 600; color: var(--primary); }
.subtitle { font-size: clamp(18px, 2vw, 22px); color: #555; margin: 16px 0 0; max-width: 50ch; }
.byline { font-size: 12px; color: #888; letter-spacing: .06em; margin-top: 20px; text-transform: uppercase; }
.hero-image { margin: 32px 0 0; padding: 0; }
.hero-image img { width: 100%; aspect-ratio: 16/9; object-fit: cover; border-radius: 6px; display: block; }

.toc { margin: 48px 0; padding: 24px; background: #f5f3ef; border-radius: 6px; }
.toc-label { font-size: 11px; letter-spacing: .22em; text-transform: uppercase; color: #777; margin-bottom: 12px; font-weight: 600; }
.toc ol { list-style: none; padding: 0; margin: 0; font-family: var(--font-display); font-size: 17px; }
.toc li { padding: 6px 0; }
.toc a { color: #222; text-decoration: none; }
.toc a:hover { color: var(--accent); }

.doc-section { margin: 64px 0; position: relative; }
.section-num { font-family: var(--font-display); font-size: 13px; color: var(--accent); font-weight: 600; letter-spacing: .12em; margin-bottom: 8px; }
.doc-section h2 { font-family: var(--font-display); font-size: clamp(24px, 3vw, 32px); font-weight: 600; line-height: 1.2; letter-spacing: -0.01em; margin: 0 0 24px; color: var(--primary); }
.doc-section p { margin: 0 0 16px; color: #2a2a2a; }
.doc-section ul, .doc-section ol { margin: 16px 0; padding-left: 22px; }
.doc-section li { margin: 6px 0; }
.doc-section a { color: var(--accent); text-decoration: underline; text-underline-offset: 2px; }
.doc-section code { background: #f0eee8; padding: 1px 6px; border-radius: 3px; font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 13.5px; }

.inline-image { margin: 28px 0; padding: 0; }
.inline-image img { width: 100%; border-radius: 6px; display: block; }
.inline-image figcaption { font-size: 13px; color: #777; margin-top: 8px; text-align: center; font-style: italic; }

.widget { margin: 28px 0; }

.palette { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; }
.palette-chip { aspect-ratio: 1.3/1; border-radius: 6px; padding: 14px; display: flex; flex-direction: column; justify-content: flex-end; }
.palette-chip .role { font-size: 10px; text-transform: uppercase; letter-spacing: .14em; opacity: .8; }
.palette-chip .name { font-size: 13px; font-weight: 600; margin-top: 4px; }
.palette-chip .hex { font-family: ui-monospace, monospace; font-size: 11px; opacity: .75; }

.product-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr)); gap: 12px; }
.product-card { padding: 14px; background: #f5f3ef; border-radius: 6px; }
.product-card .pname { font-size: 13.5px; font-weight: 500; line-height: 1.3; }
.product-card .pcat { font-size: 10px; letter-spacing: .14em; text-transform: uppercase; color: #888; margin-top: 4px; }
.product-card .price { font-family: ui-monospace, monospace; font-size: 12.5px; color: var(--accent); margin-top: 8px; }

.ad-list { display: flex; flex-direction: column; gap: 10px; }
.ad-row { padding: 14px; background: #f5f3ef; border-radius: 6px; display: grid; grid-template-columns: 32px 1fr auto; gap: 12px; align-items: center; }
.ad-row .badge { width: 32px; height: 32px; border-radius: 4px; background: var(--primary); color: #fff; display: grid; place-items: center; font-size: 12px; font-weight: 700; }
.ad-row .hl { font-size: 14px; line-height: 1.3; }
.ad-row .cta { font-size: 11px; color: #888; letter-spacing: .08em; text-transform: uppercase; }

.comp-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
.comp-row { padding: 10px 14px; background: #f5f3ef; border-radius: 6px; display: flex; flex-wrap: wrap; gap: 6px; align-items: baseline; }
.comp-row .cname { font-size: 14px; font-weight: 500; }
.comp-row .cdomain { font-size: 11px; color: #888; font-family: ui-monospace, monospace; }
.comp-row .cnote { font-size: 11px; color: #666; flex: 1 0 100%; }

.stat-block { padding: 32px; background: var(--primary); color: var(--secondary); border-radius: 6px; text-align: center; }
.stat-block .stat-value { font-family: var(--font-display); font-size: clamp(36px, 6vw, 64px); font-weight: 700; line-height: 1; }
.stat-block .stat-label { font-size: 13px; text-transform: uppercase; letter-spacing: .14em; margin-top: 8px; opacity: .85; }

.pull-quote { margin: 28px 0; padding: 16px 24px; border-left: 3px solid var(--accent); font-family: var(--font-display); font-size: 20px; line-height: 1.4; color: #2a2a2a; font-style: italic; }
.pull-quote cite { display: block; margin-top: 10px; font-size: 12px; color: #888; font-style: normal; letter-spacing: .06em; text-transform: uppercase; }

.timeline { display: flex; flex-direction: column; gap: 4px; font-family: ui-monospace, monospace; font-size: 12px; }
.t-row { display: grid; grid-template-columns: 200px 100px 1fr; gap: 12px; padding: 4px 8px; border-bottom: 1px dashed #ddd; }
.t-verb { color: #444; }
.t-status { color: var(--accent); }
.t-summary { color: #777; }

.data-table { width: 100%; border-collapse: collapse; font-size: 13.5px; }
.data-table th { text-align: left; padding: 10px 12px; background: #f0eee8; font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: .12em; }
.data-table td { padding: 10px 12px; border-bottom: 1px solid #eee; }

.endnotes { margin-top: 80px; padding-top: 24px; border-top: 1px solid #ddd; font-size: 12.5px; color: #777; }
.endnotes h3 { font-size: 11px; letter-spacing: .18em; text-transform: uppercase; font-weight: 600; color: #555; margin: 0 0 10px; }
.endnotes ul { list-style: none; padding: 0; margin: 0; }
.endnotes li { padding: 3px 0; font-family: ui-monospace, monospace; font-size: 11.5px; }

.doc-footer { margin-top: 64px; padding-top: 24px; border-top: 1px solid #ddd; font-size: 11px; color: #999; letter-spacing: .06em; text-transform: uppercase; }

@media (max-width: 600px) {
  .comp-grid { grid-template-columns: 1fr; }
  .doc { padding: 24px 16px; }
}

@media print {
  body { background: #fff; }
  .toc, .doc-footer { page-break-after: auto; }
  .doc-section { page-break-inside: avoid; }
}
`;
