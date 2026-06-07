// brand-fonts.ts — extract web fonts from a brand's homepage.
//
// Pure client-side scrape first: fetch homepage HTML, follow <link rel="stylesheet">,
// parse @font-face + font-family declarations with regex, detect Google Fonts
// and Adobe Typekit kit links, and return a structured font report.
//
// WAF fallback: if the direct homepage fetch returns 403/429/empty, fall back
// to calling POST /scrape on the managed API (cf-browser → context-dev →
// firecrawl) to get the rendered HTML, then parse that.
//
// No LLM cost. Fixed user-facing price: $0.02/call.

export interface FontFaceDeclaration {
  family: string;
  weights: number[];
  italic_supported: boolean;
  source: string;
  files?: string[];
}

export interface BrandFontsResult {
  domain: string;
  primary_font: FontFaceDeclaration | null;
  secondary_font: FontFaceDeclaration | null;
  stack_css: string | null;
  headings_stack_css: string | null;
  body_stack_css: string | null;
  found_at: string[];
  error?: string;
}

// --- CSS parsing helpers ------------------------------------------------

/** Parse all @font-face blocks from raw CSS text. */
export function parseFontFaces(
  css: string,
  _sourceUrl: string,
): Array<{ family: string; src: string; weight: string; style: string }> {
  const results: Array<{ family: string; src: string; weight: string; style: string }> = [];

  // Match @font-face { ... } blocks.
  const blockRe = /@font-face\s*\{([^}]+)\}/gi;
  let match = blockRe.exec(css);

  while (match !== null) {
    const block = match[1] ?? "";
    const family = extractCssProp(block, "font-family") ?? "";
    const src = extractCssProp(block, "src") ?? "";
    const weight = extractCssProp(block, "font-weight") ?? "400";
    const style = extractCssProp(block, "font-style") ?? "normal";

    const cleaned = family.replace(/['"]/g, "").trim();
    if (cleaned) {
      results.push({ family: cleaned, src, weight, style });
    }
    match = blockRe.exec(css);
  }

  return results;
}

/** Extract a single CSS property value from a declaration block snippet. */
function extractCssProp(block: string, prop: string): string | null {
  const re = new RegExp(`${prop}\\s*:\\s*([^;]+)`, "i");
  const m = re.exec(block);
  return m ? (m[1] ?? "").trim() : null;
}

/** Extract woff/woff2/ttf file URLs from a @font-face src value. */
function extractFontUrls(src: string, baseUrl: string): string[] {
  const urls: string[] = [];
  const urlRe = /url\(['"]?([^'")\s]+\.(?:woff2?|ttf|otf|eot))['"]?\)/gi;
  let m = urlRe.exec(src);
  while (m !== null) {
    const raw = m[1] ?? "";
    try {
      const abs = new URL(raw, baseUrl).href;
      urls.push(abs);
    } catch {
      if (raw.startsWith("http")) urls.push(raw);
    }
    m = urlRe.exec(src);
  }
  return urls;
}

// Selectors that indicate heading context.
const HEADING_RE = /(?:^|[\s,])(h[1-6]|\.(?:display|headline|heading|hero|title))(?:[\s,{>+~]|$)/i;
// Selectors that indicate body / paragraph context.
const BODY_RE = /(?:^|[\s,])(body|\.(?:body|text|content|paragraph|copy|prose))(?:[\s,{>+~]|$)/i;

/** Parse font-family declarations and their selectors from CSS. */
export function parseFontFamilyDeclarations(
  css: string,
): Array<{ selector: string; stack: string }> {
  const results: Array<{ selector: string; stack: string }> = [];

  // Match selector { ... font-family: ...; ... }
  const ruleRe = /([^{}@]+)\{([^{}]+)\}/g;
  let m = ruleRe.exec(css);

  while (m !== null) {
    const selector = (m[1] ?? "").trim();
    const declarations = m[2] ?? "";
    const stack = extractCssProp(declarations, "font-family");
    if (stack) {
      results.push({ selector, stack: stack.trim() });
    }
    m = ruleRe.exec(css);
  }

  return results;
}

/** Pick the most-used font-family stack among declarations whose selectors
 *  match the given pattern. Returns null if no matches. */
function dominantStack(
  decls: Array<{ selector: string; stack: string }>,
  pattern: RegExp,
): string | null {
  const counts = new Map<string, number>();
  for (const { selector, stack } of decls) {
    if (pattern.test(selector)) {
      counts.set(stack, (counts.get(stack) ?? 0) + 1);
    }
  }
  if (counts.size === 0) return null;
  let best = "";
  let bestCount = 0;
  for (const [stack, count] of counts) {
    if (count > bestCount) {
      best = stack;
      bestCount = count;
    }
  }
  return best || null;
}

// --- External font service detection ------------------------------------

/** Detect Google Fonts family names from a <link> href. */
export function parseGoogleFontsLink(href: string): string[] {
  // https://fonts.googleapis.com/css2?family=Inter:wght@400;700&family=Playfair+Display
  if (!href.includes("fonts.googleapis.com")) return [];
  try {
    const url = new URL(href);
    const families: string[] = [];
    for (const v of url.searchParams.getAll("family")) {
      // "Inter:wght@400;700" → "Inter"
      const name = v.split(":")[0]?.replace(/\+/g, " ") ?? "";
      if (name) families.push(name);
    }
    return families;
  } catch {
    return [];
  }
}

/** Detect Adobe Typekit kit ID from a <link> href. Returns the kit CSS URL
 *  we can fetch to discover the actual font names. */
export function parseTypekitLink(href: string): string | null {
  // https://use.typekit.net/<kit-id>.css
  if (!href.includes("use.typekit.net") && !href.includes("p.typekit.net")) return null;
  return href;
}

// --- Weight string → number[] ------------------------------------------

function parseWeights(weightStr: string): number[] {
  const clean = weightStr
    .toLowerCase()
    .replace(/bold/g, "700")
    .replace(/normal/g, "400");
  const numbers = [...clean.matchAll(/\d+/g)].map((m) => Number(m[0])).filter((n) => n >= 100);
  if (numbers.length === 0) return [400];
  if (numbers.length === 1) return [numbers[0] as number];
  // "400 700" or "100 900" (range) → expand to common axis stops
  const [lo, hi] = [Math.min(...numbers), Math.max(...numbers)];
  const stops = [100, 200, 300, 400, 500, 600, 700, 800, 900];
  return stops.filter((s) => s >= lo && s <= hi);
}

// --- Main extractor -----------------------------------------------------

interface FetchOptions {
  /** Max stylesheet fetches (to avoid runaway). Default 20. */
  maxSheets?: number;
  /** User-agent for HTTP requests. */
  userAgent?: string;
  /** Override API base URL for WAF-bypass fallback. */
  baseUrl?: string;
}

// Status codes that indicate WAF / rate-limit — trigger API fallback.
const WAF_STATUSES = new Set([403, 429, 503]);

export async function extractBrandFonts(
  domain: string,
  opts: FetchOptions = {},
): Promise<BrandFontsResult> {
  const maxSheets = opts.maxSheets ?? 20;
  const ua =
    opts.userAgent ??
    "Mozilla/5.0 (compatible; brandnana-font-extractor/1.0; +https://brandnana.net)";

  const homeUrl = domain.startsWith("http") ? domain : `https://${domain}`;
  const normalizedDomain = new URL(homeUrl).hostname;

  const foundAt: string[] = [];

  // --- Step 1: fetch homepage (direct, then API fallback) -------------
  let html = "";
  let usedApiFallback = false;

  try {
    const res = await fetch(homeUrl, {
      headers: { "User-Agent": ua, Accept: "text/html,*/*" },
      redirect: "follow",
      signal: AbortSignal.timeout(15_000),
    });
    if (WAF_STATUSES.has(res.status)) {
      // Fall through to API fallback below.
      html = "";
    } else {
      html = await res.text();
    }
  } catch (err) {
    // Network error or timeout — try API fallback before giving up.
    html = "";
    // Only surface the original error if the API fallback also fails.
    const originalErr = err instanceof Error ? err.message : String(err);

    // --- Step 1b: API fallback -----------------------------------------
    // Import clientFromEnv lazily so this module stays free of side-effects
    // when used purely as a parsing library.
    try {
      const { clientFromEnv } = await import("../client.js");
      const client = await clientFromEnv(opts.baseUrl);
      const scrapeResult = await client.scrape.fetch(homeUrl, { expect: "html" });
      if (scrapeResult.ok && scrapeResult.body) {
        html = scrapeResult.body;
        usedApiFallback = true;
      } else {
        return {
          domain: normalizedDomain,
          primary_font: null,
          secondary_font: null,
          stack_css: null,
          headings_stack_css: null,
          body_stack_css: null,
          found_at: [],
          error: `fetch_failed: ${originalErr}`,
        };
      }
    } catch {
      return {
        domain: normalizedDomain,
        primary_font: null,
        secondary_font: null,
        stack_css: null,
        headings_stack_css: null,
        body_stack_css: null,
        found_at: [],
        error: `fetch_failed: ${originalErr}`,
      };
    }
  }

  // --- Step 1c: WAF-blocked direct fetch — API fallback ---------------
  if (!html && !usedApiFallback) {
    try {
      const { clientFromEnv } = await import("../client.js");
      const client = await clientFromEnv(opts.baseUrl);
      const scrapeResult = await client.scrape.fetch(homeUrl, { expect: "html" });
      if (scrapeResult.ok && scrapeResult.body) {
        html = scrapeResult.body;
        usedApiFallback = true;
      }
    } catch {
      // API also failed — fall through to empty-body handling below.
    }
  }

  if (!html) {
    return {
      domain: normalizedDomain,
      primary_font: null,
      secondary_font: null,
      stack_css: null,
      headings_stack_css: null,
      body_stack_css: null,
      found_at: [],
      error: "fetch_failed: waf_blocked_all_tiers",
    };
  }

  void usedApiFallback; // acknowledged — may be used for telemetry later

  // --- Step 2: collect stylesheet URLs + inline style blocks ----------
  const sheetUrls: string[] = [];
  const inlineCssBlocks: string[] = [];

  // <link rel="stylesheet" href="..."> (also handles rel="preload" as="style")
  const linkRe = /<link[^>]+>/gi;
  let lm = linkRe.exec(html);
  while (lm !== null) {
    const tag = lm[0] ?? "";
    if (!/rel=["'][^"']*stylesheet[^"']*["']/i.test(tag) && !/as=["']style["']/i.test(tag)) {
      // Check Google Fonts / Typekit regardless of rel
      const hrefM = /href=["']([^"']+)["']/i.exec(tag);
      if (hrefM) {
        const h = hrefM[1] ?? "";
        if (h.includes("fonts.googleapis.com") || h.includes("typekit.net")) {
          sheetUrls.push(h);
        }
      }
      lm = linkRe.exec(html);
      continue;
    }
    const hrefM = /href=["']([^"']+)["']/i.exec(tag);
    if (hrefM) {
      const href = hrefM[1] ?? "";
      try {
        const abs = new URL(href, homeUrl).href;
        sheetUrls.push(abs);
      } catch {
        // relative href without valid base — skip
      }
    }
    lm = linkRe.exec(html);
  }

  // <style> blocks
  const styleRe = /<style[^>]*>([\s\S]*?)<\/style>/gi;
  let sm = styleRe.exec(html);
  while (sm !== null) {
    const content = sm[1] ?? "";
    if (content.trim()) inlineCssBlocks.push(content);
    sm = styleRe.exec(html);
  }

  // --- Step 3: fetch external sheets (capped) -------------------------
  const sheetsToFetch = sheetUrls.slice(0, maxSheets);
  const sheetCssMap = new Map<string, string>();

  await Promise.allSettled(
    sheetsToFetch.map(async (url) => {
      try {
        const res = await fetch(url, {
          headers: { "User-Agent": ua, Accept: "text/css,*/*" },
          redirect: "follow",
          signal: AbortSignal.timeout(10_000),
        });
        if (res.ok) {
          sheetCssMap.set(url, await res.text());
        }
      } catch {
        // skip failed sheets
      }
    }),
  );

  // --- Step 4: detect external font services --------------------------
  const googleFontFamilies: string[] = [];
  const typekitFamilies: string[] = [];

  for (const url of sheetUrls) {
    const gf = parseGoogleFontsLink(url);
    googleFontFamilies.push(...gf);

    const tkUrl = parseTypekitLink(url);
    if (tkUrl) {
      // Fetch Typekit CSS to get actual family names
      const css = sheetCssMap.get(tkUrl) ?? "";
      // Typekit CSS contains @font-face rules with the real family names
      const faces = parseFontFaces(css, tkUrl);
      typekitFamilies.push(...faces.map((f) => f.family));
    }
  }

  // --- Step 5: parse @font-face + font-family from all CSS ------------
  const allFontFaces: Array<{
    family: string;
    src: string;
    weight: string;
    style: string;
    sheetUrl: string;
  }> = [];
  const allFamilyDecls: Array<{ selector: string; stack: string }> = [];

  // Inline styles
  for (const css of inlineCssBlocks) {
    const faces = parseFontFaces(css, homeUrl);
    allFontFaces.push(...faces.map((f) => ({ ...f, sheetUrl: `${homeUrl}#inline` })));
    allFamilyDecls.push(...parseFontFamilyDeclarations(css));
  }

  // External sheets
  for (const [url, css] of sheetCssMap) {
    const faces = parseFontFaces(css, url);
    allFontFaces.push(...faces.map((f) => ({ ...f, sheetUrl: url })));
    allFamilyDecls.push(...parseFontFamilyDeclarations(css));
    foundAt.push(url);
  }

  // --- Step 6: synthesize Google Fonts as synthetic @font-face entries
  for (const family of googleFontFamilies) {
    if (!allFontFaces.some((f) => f.family.toLowerCase() === family.toLowerCase())) {
      allFontFaces.push({
        family,
        src: "Google Fonts CDN",
        weight: "100 900",
        style: "normal italic",
        sheetUrl: sheetUrls.find((u) => u.includes("fonts.googleapis.com")) ?? "google-fonts",
      });
    }
  }

  for (const family of typekitFamilies) {
    if (!allFontFaces.some((f) => f.family.toLowerCase() === family.toLowerCase())) {
      allFontFaces.push({
        family,
        src: "Adobe Fonts (Typekit)",
        weight: "400",
        style: "normal",
        sheetUrl: sheetUrls.find((u) => u.includes("typekit.net")) ?? "adobe-fonts",
      });
    }
  }

  // --- Step 7: no fonts found -----------------------------------------
  if (allFontFaces.length === 0 && allFamilyDecls.length === 0) {
    return {
      domain: normalizedDomain,
      primary_font: null,
      secondary_font: null,
      stack_css: null,
      headings_stack_css: null,
      body_stack_css: null,
      found_at: [],
      error: "no_fonts_detected",
    };
  }

  // --- Step 8: rank font-face declarations ----------------------------
  // Group by family, accumulate weights and italic support.
  const familyMap = new Map<
    string,
    { weights: Set<number>; italic: boolean; src: string; files: Set<string>; sheetUrl: string }
  >();

  for (const face of allFontFaces) {
    const key = face.family.toLowerCase();
    if (!familyMap.has(key)) {
      familyMap.set(key, {
        weights: new Set(),
        italic: false,
        src: face.src,
        files: new Set(),
        sheetUrl: face.sheetUrl,
      });
    }
    const entry = familyMap.get(key);
    if (!entry) continue;
    for (const w of parseWeights(face.weight)) {
      entry.weights.add(w);
    }
    if (/italic/i.test(face.style)) entry.italic = true;

    // Collect font file URLs
    const urls = extractFontUrls(face.src, face.sheetUrl);
    for (const u of urls) entry.files.add(u);
  }

  // Self-hosted fonts (non-CDN src) get priority.
  const selfHosted = [...familyMap.entries()].filter(
    ([, v]) =>
      !v.src.includes("fonts.googleapis.com") &&
      !v.src.includes("Google Fonts") &&
      !v.src.includes("Adobe Fonts") &&
      !v.src.includes("typekit.net"),
  );
  const external = [...familyMap.entries()].filter(
    ([, v]) =>
      v.src.includes("fonts.googleapis.com") ||
      v.src.includes("Google Fonts") ||
      v.src.includes("Adobe Fonts") ||
      v.src.includes("typekit.net"),
  );

  const ranked = selfHosted.length > 0 ? selfHosted : external;

  function toDeclaration(
    key: string,
    entry: {
      weights: Set<number>;
      italic: boolean;
      src: string;
      files: Set<string>;
      sheetUrl: string;
    },
  ): FontFaceDeclaration {
    const files = [...entry.files];
    return {
      family: key,
      weights: [...entry.weights].sort((a, b) => a - b),
      italic_supported: entry.italic,
      source:
        entry.src.startsWith("http") || entry.files.size > 0
          ? `self-hosted @font-face from ${entry.sheetUrl}`
          : entry.src,
      ...(files.length > 0 ? { files } : {}),
    };
  }

  const primaryEntry = ranked[0];
  const secondaryEntry = ranked[1];
  const primary = primaryEntry ? toDeclaration(primaryEntry[0], primaryEntry[1]) : null;
  const secondary = secondaryEntry ? toDeclaration(secondaryEntry[0], secondaryEntry[1]) : null;

  // --- Step 9: heading + body stacks ----------------------------------
  const headingsStack = dominantStack(allFamilyDecls, HEADING_RE);
  const bodyStack = dominantStack(allFamilyDecls, BODY_RE);

  // Global stack: look for body or :root or * selector
  const globalDecl = allFamilyDecls.find((d) => /^(?:body|html|:root|\*)$/.test(d.selector.trim()));
  const stackCss = globalDecl?.stack ?? primary?.family ?? null;

  // Build found_at with inline marker if inline blocks had fonts
  if (inlineCssBlocks.some((c) => /@font-face/i.test(c) || /font-family\s*:/i.test(c))) {
    foundAt.unshift(`${homeUrl}#inline-style`);
  }

  return {
    domain: normalizedDomain,
    primary_font: primary,
    secondary_font: secondary,
    stack_css: stackCss,
    headings_stack_css: headingsStack,
    body_stack_css: bodyStack,
    found_at: foundAt,
  };
}
