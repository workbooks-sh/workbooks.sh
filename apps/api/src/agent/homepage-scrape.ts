// Homepage CSS + meta scraper. Extracts the brand's REAL design tokens
// (colors, fonts) directly from the served HTML and its inline / linked
// stylesheets. The output is fed to Cerebras as observed evidence so the
// style_signal is grounded, not training-data hallucination.
//
// Two-stage fetch:
//   1. Direct fetch with realistic Chrome UA. Fast (< 2s) and works for most
//      sites.
//   2. If direct fetch returns <2KB of HTML (almost certainly a WAF challenge
//      page or bot-block), fall back to Cloudflare Browser Rendering via the
//      BROWSER binding. Real headless Chromium, full JS execution, gets past
//      every bot wall we've hit. Costs ~$0.001/render and adds ~3s.
//
// Free, no vendor key. Works against any public homepage.
//
// Approach:
//   1. Fetch the homepage HTML (cap response at 500 KB).
//   2. Parse <title>, <meta name="description">, og:title, og:description,
//      og:image, theme-color from <meta>.
//   3. Parse inline <style>…</style> blocks (cap each at 200 KB).
//   4. Follow up to 5 <link rel="stylesheet"> with same-origin or CDN
//      hrefs (cap each at 300 KB, total fetch budget 1 MB).
//   5. From all the collected CSS:
//      - Extract :root and body custom properties whose name suggests
//        a brand token: --color, --primary, --secondary, --accent,
//        --brand, --background, --surface, --fg, --text.
//      - Extract font-family declarations on body, html, h1-h6, .hero,
//        .headline*, .display* — capture the FIRST custom font in each
//        stack (skip system/generic families like sans-serif, monospace,
//        -apple-system, Arial, Helvetica, etc).
//      - Score colors by appearance count to surface the most-used ones.

import type { Bindings } from "../env.js";
import { browserHeaders } from "../scrape/headers.js";
import { renderPage } from "../scrape/browser.js";

const FETCH_TIMEOUT_MS = 6000;
const HTML_CAP = 500_000;
const CSS_FILE_CAP = 300_000;
const MAX_LINKED_STYLESHEETS = 5;
const CSS_BUDGET_TOTAL = 1_500_000;

const GENERIC_FONTS = new Set([
  "sans-serif", "serif", "monospace", "system-ui", "ui-sans-serif", "ui-serif",
  "ui-monospace", "cursive", "fantasy", "math", "fangsong", "emoji",
  "-apple-system", "blinkmacsystemfont", "helvetica neue", "helvetica",
  "arial", "courier", "courier new", "times", "times new roman", "georgia",
  "verdana", "tahoma", "trebuchet ms", "segoe ui", "segoe ui emoji",
  "segoe ui symbol", "apple color emoji", "noto color emoji", "inherit",
  "unset", "initial", "revert",
]);

export interface CssVarHit {
  name: string;
  value: string;
  source: "inline" | "linked";
}

export interface ColorHit {
  hex: string;
  count: number;
  /** Where it appeared (var name OR property name like 'background-color'). */
  via: string[];
}

export interface HomepageEvidence {
  url: string;
  fetched_at: string;
  /** Hard error if we couldn't fetch the page at all. */
  fetch_error?: string;
  meta: {
    title?: string;
    description?: string;
    og_title?: string;
    og_description?: string;
    og_image?: string;
    theme_color?: string;
    language?: string;
  };
  /** All CSS custom properties whose name hints at brand identity. */
  brand_css_vars: CssVarHit[];
  /** Distinct hex colors ranked by occurrence count. */
  colors_ranked: ColorHit[];
  /** Custom font families found on body / hero / heading selectors. */
  fonts: Array<{ family: string; weight?: string; used_for: string }>;
  /** Approximate counts so we know how much CSS we actually looked at. */
  stats: {
    html_bytes: number;
    inline_style_blocks: number;
    linked_stylesheets_fetched: number;
    total_css_bytes: number;
  };
}

// ── Public entry ─────────────────────────────────────────────────────────────

const MIN_HTML_BYTES_FOR_SUCCESS = 2_000;

export async function scrapeHomepageEvidence(
  domain: string,
  opts: { browser?: Fetcher } = {},
): Promise<HomepageEvidence> {
  const url = `https://${domain}/`;
  const fetched_at = new Date().toISOString();
  const ev: HomepageEvidence = {
    url, fetched_at,
    meta: {},
    brand_css_vars: [],
    colors_ranked: [],
    fonts: [],
    stats: { html_bytes: 0, inline_style_blocks: 0, linked_stylesheets_fetched: 0, total_css_bytes: 0 },
  };

  let html: string;
  let usedBrowser = false;
  try {
    html = await fetchCapped(url, HTML_CAP);
  } catch (e) {
    // Direct fetch threw — try Browser Rendering before giving up.
    if (opts.browser) {
      try {
        html = await fetchViaBrowser(opts.browser, url);
        usedBrowser = true;
      } catch (e2) {
        ev.fetch_error = `direct ${(e as Error).message} + browser ${(e2 as Error).message}`;
        return ev;
      }
    } else {
      ev.fetch_error = (e as Error).message;
      return ev;
    }
  }
  ev.stats.html_bytes = html.length;

  // If direct fetch returned suspiciously little HTML (bot challenge page,
  // "please enable JavaScript" stub, empty body), retry with Browser Rendering.
  if (!usedBrowser && html.length < MIN_HTML_BYTES_FOR_SUCCESS && opts.browser) {
    try {
      const rendered = await fetchViaBrowser(opts.browser, url);
      if (rendered.length > html.length) {
        html = rendered;
        usedBrowser = true;
        ev.stats.html_bytes = html.length;
      }
    } catch {
      // Fall through with the small HTML we already have.
    }
  }
  (ev.stats as any).used_browser_rendering = usedBrowser;

  ev.meta = extractMeta(html);

  const inlineCss = extractInlineStyles(html);
  ev.stats.inline_style_blocks = inlineCss.length;

  const linkedHrefs = extractStylesheetLinks(html, url).slice(0, MAX_LINKED_STYLESHEETS);
  const linkedCss: string[] = [];
  let budget = CSS_BUDGET_TOTAL - inlineCss.reduce((s, c) => s + c.length, 0);
  for (const href of linkedHrefs) {
    if (budget <= 0) break;
    try {
      const css = await fetchCapped(href, Math.min(CSS_FILE_CAP, budget));
      linkedCss.push(css);
      budget -= css.length;
      ev.stats.linked_stylesheets_fetched++;
    } catch {
      // Ignore individual stylesheet failures (CDN may block our UA, etc).
    }
  }
  ev.stats.total_css_bytes = inlineCss.reduce((s, c) => s + c.length, 0) + linkedCss.reduce((s, c) => s + c.length, 0);

  // Merge: inline first (overrides), then linked.
  const allCss: Array<{ css: string; source: "inline" | "linked" }> = [
    ...inlineCss.map((css) => ({ css, source: "inline" as const })),
    ...linkedCss.map((css) => ({ css, source: "linked" as const })),
  ];

  ev.brand_css_vars = extractBrandCssVars(allCss);
  // Seed ranking with the parsed <meta theme-color> (previously parsed but never
  // used) so it always lands in the palette. HARVEST always-unions theme-color
  // + CSS-var + dominant colors downstream; rankColors guarantees they're all
  // present here, theme-color and brand vars weighted highest.
  const seeds = ev.meta.theme_color ? [ev.meta.theme_color] : [];
  ev.colors_ranked = rankColors(allCss, ev.brand_css_vars, seeds);
  ev.fonts = extractFonts(allCss);

  return ev;
}

// ── HTTP ─────────────────────────────────────────────────────────────────────

// CF Browser Rendering — full headless Chromium for sites our direct fetch
// gets bot-blocked on. Routes through the shared scrape/browser.ts renderPage()
// (the real env.BROWSER binding) instead of the old fictional
// `https://browser-rendering.cf/v1/content` host. Throws on failure so the
// caller's try/catch keeps the small-but-real direct HTML.
async function fetchViaBrowser(browser: Fetcher, url: string): Promise<string> {
  const r = await renderPage({ BROWSER: browser } as Bindings, url, { waitMs: 0 });
  if (!r.ok || r.html === undefined) {
    throw new Error(`browser render failed: ${r.error ?? "no_html"}`);
  }
  return r.html.length > HTML_CAP ? r.html.slice(0, HTML_CAP) : r.html;
}

async function fetchCapped(url: string, maxBytes: number): Promise<string> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), FETCH_TIMEOUT_MS);
  try {
    // Realistic Chrome fingerprint (shared browserHeaders) — many major brand
    // sites bot-block obvious crawler UAs. We're scraping public marketing
    // pages, not data; matching a real browser is necessary to get past WAFs.
    // Accept widened to include text/css since this fetcher also pulls linked
    // stylesheets.
    const r = await fetch(url, {
      headers: browserHeaders({
        accept:
          "text/html,application/xhtml+xml,application/xml;q=0.9,text/css,image/avif,image/webp,*/*;q=0.8",
      }),
      redirect: "follow",
      signal: ctrl.signal,
    });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    const text = await r.text();
    return text.length > maxBytes ? text.slice(0, maxBytes) : text;
  } finally {
    clearTimeout(t);
  }
}

// ── HTML extraction ──────────────────────────────────────────────────────────

function extractMeta(html: string): HomepageEvidence["meta"] {
  const out: HomepageEvidence["meta"] = {};
  out.title = first(html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1])?.trim();
  out.description = metaContent(html, "description");
  out.og_title = metaContent(html, "og:title") ?? metaContent(html, "twitter:title");
  out.og_description = metaContent(html, "og:description") ?? metaContent(html, "twitter:description");
  out.og_image = metaContent(html, "og:image") ?? metaContent(html, "twitter:image");
  out.theme_color = metaContent(html, "theme-color");
  out.language = first(html.match(/<html[^>]+lang=["']([^"']+)["']/i)?.[1])?.trim();
  return out;
}

function metaContent(html: string, key: string): string | undefined {
  const escKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re1 = new RegExp(`<meta[^>]+(?:name|property)=["']${escKey}["'][^>]+content=["']([^"']*)["']`, "i");
  const re2 = new RegExp(`<meta[^>]+content=["']([^"']*)["'][^>]+(?:name|property)=["']${escKey}["']`, "i");
  return first(html.match(re1)?.[1]) ?? first(html.match(re2)?.[1]);
}

function first(s: string | undefined): string | undefined {
  return s ? s.replace(/\s+/g, " ").trim().slice(0, 600) : undefined;
}

function extractInlineStyles(html: string): string[] {
  const out: string[] = [];
  const re = /<style[^>]*>([\s\S]*?)<\/style>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    out.push(m[1]!);
  }
  return out;
}

function extractStylesheetLinks(html: string, baseUrl: string): string[] {
  const out: string[] = [];
  const re = /<link[^>]+rel=["']stylesheet["'][^>]+href=["']([^"']+)["']/gi;
  const re2 = /<link[^>]+href=["']([^"']+)["'][^>]+rel=["']stylesheet["']/gi;
  for (const re_ of [re, re2]) {
    let m: RegExpExecArray | null;
    while ((m = re_.exec(html)) !== null) {
      try {
        out.push(new URL(m[1]!, baseUrl).toString());
      } catch { /* skip malformed href */ }
    }
  }
  return Array.from(new Set(out));
}

// ── CSS extraction ───────────────────────────────────────────────────────────

const BRAND_VAR_RE = /\b(color|primary|secondary|accent|brand|background|bg|surface|foreground|fg|text|highlight|link)\b/i;

function extractBrandCssVars(blocks: Array<{ css: string; source: "inline" | "linked" }>): CssVarHit[] {
  const out: CssVarHit[] = [];
  const seen = new Set<string>();
  const decl = /--([\w-]+)\s*:\s*([^;{}]+);/g;
  for (const { css, source } of blocks) {
    let m: RegExpExecArray | null;
    while ((m = decl.exec(css)) !== null) {
      const name = m[1]!.trim();
      const value = m[2]!.trim();
      if (!BRAND_VAR_RE.test(name)) continue;
      const key = `${name}=${value}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({ name: `--${name}`, value, source });
    }
  }
  return out.slice(0, 80);
}

function normalizeHex(v: string): string | null {
  v = v.trim().toLowerCase();
  if (/^#[0-9a-f]{3}$/i.test(v)) {
    return "#" + v.slice(1).split("").map((c) => c + c).join("");
  }
  if (/^#[0-9a-f]{6}$/i.test(v)) return v;
  if (/^#[0-9a-f]{8}$/i.test(v)) return v.slice(0, 7); // drop alpha
  const rgb = v.match(/^rgba?\s*\(\s*(\d+)\s*[, ]\s*(\d+)\s*[, ]\s*(\d+)/i);
  if (rgb) {
    const [r, g, b] = [+rgb[1]!, +rgb[2]!, +rgb[3]!];
    return rgbToHex(r, g, b);
  }
  // HSL — including the bare-channel form Tailwind/shadcn store in CSS vars,
  // e.g. `--primary: 222.2 47.4% 11.2%` or `hsl(222.2 47.4% 11.2%)`.
  const hsl = v.match(
    /^hsla?\s*\(\s*([\d.]+)(?:deg)?\s*[, ]\s*([\d.]+)%\s*[, ]\s*([\d.]+)%/i,
  ) ?? v.match(/^([\d.]+)(?:deg)?\s+([\d.]+)%\s+([\d.]+)%/);
  if (hsl) {
    const [r, g, b] = hslToRgb(+hsl[1]!, +hsl[2]!, +hsl[3]!);
    return rgbToHex(r, g, b);
  }
  return null;
}

function rgbToHex(r: number, g: number, b: number): string {
  return (
    "#" +
    [r, g, b]
      .map((n) => Math.max(0, Math.min(255, Math.round(n))).toString(16).padStart(2, "0"))
      .join("")
  );
}

/** HSL (h in degrees, s/l in 0-100) → [r,g,b] in 0-255. */
function hslToRgb(h: number, s: number, l: number): [number, number, number] {
  h = ((h % 360) + 360) % 360;
  const sN = Math.max(0, Math.min(100, s)) / 100;
  const lN = Math.max(0, Math.min(100, l)) / 100;
  const c = (1 - Math.abs(2 * lN - 1)) * sN;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = lN - c / 2;
  let r = 0, g = 0, b = 0;
  if (h < 60) [r, g, b] = [c, x, 0];
  else if (h < 120) [r, g, b] = [x, c, 0];
  else if (h < 180) [r, g, b] = [0, c, x];
  else if (h < 240) [r, g, b] = [0, x, c];
  else if (h < 300) [r, g, b] = [x, 0, c];
  else [r, g, b] = [c, 0, x];
  return [(r + m) * 255, (g + m) * 255, (b + m) * 255];
}

function rankColors(
  blocks: Array<{ css: string; source: "inline" | "linked" }>,
  vars: CssVarHit[],
  seeds: string[] = [],
): ColorHit[] {
  const counts = new Map<string, { count: number; via: Set<string> }>();
  const bump = (hex: string, via: string, weight = 1) => {
    const v = counts.get(hex) ?? { count: 0, via: new Set() };
    v.count += weight; v.via.add(via);
    counts.set(hex, v);
  };

  // Highest weight: seed colors (parsed <meta theme-color>). Each counts 8× so
  // theme-color is guaranteed into the palette even on minimal CSS.
  for (const raw of seeds) {
    const hex = normalizeHex(raw);
    if (hex) bump(hex, "theme-color", 8);
  }

  // Next weight: brand CSS vars (each counts 5×). Now resolves HSL var values
  // (Tailwind/shadcn) too via the widened normalizeHex.
  for (const cv of vars) {
    const hex = normalizeHex(cv.value);
    if (hex) bump(hex, cv.name, 5);
  }

  // Then sweep all CSS for hex/rgb/hsl values in color/background-color/border-color.
  const colorRe = /(?:^|[^a-z-])(color|background|background-color|border|border-color|fill|stroke)\s*:\s*([^;{}]+);/gi;
  for (const { css } of blocks) {
    let m: RegExpExecArray | null;
    while ((m = colorRe.exec(css)) !== null) {
      const prop = m[1]!.toLowerCase();
      const val = m[2]!;
      // Multiple values possible (e.g. border: 1px solid #abc)
      const candidates =
        val.match(/#[0-9a-f]{3,8}\b|rgba?\([^)]+\)|hsla?\([^)]+\)/gi) ?? [];
      for (const c of candidates) {
        const hex = normalizeHex(c);
        if (hex) bump(hex, prop);
      }
    }
  }

  // Union output: theme-color + CSS-var colors are always retained (even if
  // they didn't appear in the swept declarations), then dominant colors fill
  // the rest of the 12 slots by occurrence. HARVEST always-unions these.
  const ranked = Array.from(counts.entries())
    .map(([hex, v]) => ({ hex, count: v.count, via: Array.from(v.via).slice(0, 6) }))
    .sort((a, b) => b.count - a.count);

  const must = new Set<string>();
  for (const raw of seeds) {
    const hex = normalizeHex(raw);
    if (hex) must.add(hex);
  }
  for (const cv of vars) {
    const hex = normalizeHex(cv.value);
    if (hex) must.add(hex);
  }

  const head = ranked.filter((c) => must.has(c.hex));
  const tail = ranked.filter((c) => !must.has(c.hex));
  return [...head, ...tail].slice(0, 12);
}

function extractFonts(blocks: Array<{ css: string; source: "inline" | "linked" }>): HomepageEvidence["fonts"] {
  const out: HomepageEvidence["fonts"] = [];
  const seen = new Set<string>();
  // Selectors we care about: body, html, h1-h6, .hero, .headline*, .display*
  const re = /(body|html|h[1-6]|\.hero[\w-]*|\.headline[\w-]*|\.display[\w-]*|\.brand[\w-]*)\s*(?:,\s*[^{]+)?\s*\{[^}]*font-family\s*:\s*([^;}]+)[;}]/gi;
  for (const { css } of blocks) {
    let m: RegExpExecArray | null;
    while ((m = re.exec(css)) !== null) {
      const selector = m[1]!;
      const stack = m[2]!;
      const first = pickFirstCustomFont(stack);
      if (!first) continue;
      const key = `${first}@${selector}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({ family: first, used_for: selector });
      if (out.length >= 8) return out;
    }
  }
  return out;
}

function pickFirstCustomFont(stack: string): string | null {
  // Tokens are comma-separated, may be quoted, may contain spaces.
  const tokens = stack.split(",").map((t) => t.trim().replace(/^["']|["']$/g, "").replace(/\s+/g, " "));
  for (const t of tokens) {
    if (!t) continue;
    if (t.startsWith("var(")) continue;
    if (GENERIC_FONTS.has(t.toLowerCase())) continue;
    return t;
  }
  return null;
}
