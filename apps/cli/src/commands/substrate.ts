// `brandnana substrate build [workdir]` — the DETERMINISTIC RENDER half of the
// gather→render split.
//
// PROBLEM this fixes: the GATHER agent hand-writes the .org substrate, so it
// summarizes (1 product instead of 1358), reuses one image hash for everything,
// and invents dates / ad-ids / costs. The agent is great at the ADAPTIVE crawl
// (climbing the escalation chain) but a liability as a faithful transcriber.
//
// FIX: this command reads the workdir the agent already produced — purely local,
// NO LLM, NO network — and emits the OQL-queryable org files faithfully:
//
//   raw/*.json + .brandnana/brandnana.sqlite + social/*.json + *_cost.txt
//        ↓ deterministic render (this file)
//   brand.org · catalog/products.org · social/<platform>.org · ads.org ·
//   harvest-provenance.org
//
// Every product comes from SELECT * over the SQLite products table; every image
// URL is the per-row product_images.url (already rewritten to the R2
// /assets/<sha> URL by `catalog crawl --mirror`); every timestamp is a real file
// mtime / epoch-ms column; every VENDOR_COST is the usd_with_margin parsed from
// the matching <verb>_cost.txt [brandnana-cost] line. Structurally impossible to
// summarize or fabricate.
//
// Conforms to the four templates so the strategist's OQL gates resolve:
//   brand.org.template / products.org.template / timeline.org.template
//   (apps/api/src/book/templates/*) and the :point:+STATUS universal convention
//   from substrates/brandnana/profile/skills/write-substrate.org.
//
// Idempotent: re-running over the same workdir produces the same files.

import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import type { Brand, Product } from "@brandnana/schema";
import type { Command } from "commander";
import pkg from "../../package.json" with { type: "json" };
import { emit, progress, runAction } from "../output.js";
import Database from "../sqlite.js";
import type { DbLike } from "../sqlite.js";

// ── small local helpers ──────────────────────────────────────────────────────

/** Strip leading www. and the TLD: "www.tecovas.com" → "tecovas". */
function slugFromDomain(domain: string): string {
  return domain.replace(/^www\./, "").replace(/\..*$/, "");
}

/** kebab-case slug for an :ID: from a free-text title or external id. */
function slugify(s: string): string {
  return (
    s
      .toLowerCase()
      .normalize("NFKD")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 80) || "item"
  );
}

/** Org property/body sanitiser — keep values single-line so the drawer parses. */
function oneLine(s: unknown): string {
  if (s == null) return "";
  return String(s)
    .replace(/\r?\n+/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function isoFromMs(ms: number): string {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
}

// ── R2 media gating ───────────────────────────────────────────────────────────
//
// Singleton media (logo, screenshot, ad creative) is only fidelity-valid when it
// is a canonical R2 asset URL. The gather verbs mirror them with --mirror; if a
// media point still carries a raw vendor URL (favicon.svg, media.brand.dev, a
// Meta CDN URL, or a *.workers.dev host) it was NOT mirrored. We MUST NOT emit a
// raw vendor hotlink into the substrate — the validator would flag it malformed
// and downstream consumers would hot-link a vendor URL that can rot or be
// referer-gated. Instead we blank the URL and emit a needs_mirror marker so the
// point is an honest gap, not a green hotlink.

/** Canonical R2 asset shape — MUST match substrate-check.ts R2_ASSET_RE. */
const R2_ASSET_RE = /^https:\/\/api\.brandnana\.net\/assets\/[0-9a-f]+(?:\.[a-z0-9]+)?$/i;

function isR2Asset(url: string | null | undefined): boolean {
  return !!url && R2_ASSET_RE.test(url);
}

/**
 * Resolve a singleton media URL for emission: keep it only if it is a canonical
 * R2 asset; otherwise drop the raw vendor URL (never hotlink) and report
 * needs_mirror. `url` empty + present=false ⇒ the point was never captured.
 */
function resolveMediaUrl(raw: string | null | undefined): {
  url: string;
  status: "ok" | "needs_mirror" | "failed";
  note: string;
} {
  const v = (raw ?? "").trim();
  if (!v) return { url: "", status: "failed", note: "" };
  if (isR2Asset(v)) return { url: v, status: "ok", note: "" };
  // Captured but not an R2 asset → withhold the hotlink, mark needs_mirror.
  return { url: "", status: "needs_mirror", note: `unmirrored vendor URL withheld: ${v}` };
}

function readJsonIf<T>(path: string): T | null {
  if (!existsSync(path)) return null;
  try {
    return JSON.parse(readFileSync(path, "utf8")) as T;
  } catch {
    return null;
  }
}

function mtimeMs(path: string): number | null {
  try {
    return Math.round(statSync(path).mtimeMs);
  } catch {
    return null;
  }
}

/** First defined value among the given keys of a loosely-typed record. */
function pick(obj: Record<string, unknown>, ...keys: string[]): unknown {
  for (const k of keys) {
    const v = obj[k];
    if (v !== undefined && v !== null) return v;
  }
  return undefined;
}

/** Append `value` to the array bucket for `key`, creating it on first use. */
function groupPush<V>(map: Map<string, V[]>, key: string, value: V): void {
  const bucket = map.get(key);
  if (bucket) bucket.push(value);
  else map.set(key, [value]);
}

/** Render an org :PROPERTIES: drawer from ordered [key,value] pairs. */
function propsDrawer(pairs: Array<[string, unknown]>, indent: string): string {
  const lines = [`${indent}:PROPERTIES:`];
  for (const [k, v] of pairs) {
    lines.push(`${indent}:${k}:${" ".repeat(Math.max(1, 14 - k.length))}${oneLine(v)}`);
  }
  lines.push(`${indent}:END:`);
  return lines.join("\n");
}

// ── cost-line parsing: VENDOR_COST ← usd_with_margin from *_cost.txt ──────────
//
// Format (resolve.ts:46-54):
//   [brandnana-cost] usd=N usd_at_cost=N usd_with_margin=N margin=N capability=X …

interface CostRecord {
  usd_with_margin: number | null;
  capability: string | null;
}

function parseCostLine(text: string): CostRecord {
  const line = text.split(/\r?\n/).find((l) => l.includes("[brandnana-cost]")) ?? "";
  const grab = (key: string): string | null => {
    const m = line.match(new RegExp(`${key}=([^\\s]+)`));
    return m ? (m[1] ?? null) : null;
  };
  const wm = grab("usd_with_margin");
  return {
    usd_with_margin: wm != null ? Number.parseFloat(wm) : null,
    capability: grab("capability"),
  };
}

/** Index every *_cost.txt in the workdir by its verb stem (filename sans _cost.txt). */
function loadCostFiles(workdir: string): Map<string, { cost: CostRecord; mtime: number | null }> {
  const out = new Map<string, { cost: CostRecord; mtime: number | null }>();
  let entries: string[] = [];
  try {
    entries = readdirSync(workdir);
  } catch {
    return out;
  }
  for (const name of entries) {
    if (!name.endsWith("_cost.txt")) continue;
    const full = join(workdir, name);
    const stem = name.replace(/_cost\.txt$/, ""); // e.g. "brand_fetch", "catalog_crawl"
    out.set(stem, { cost: parseCostLine(readFileSync(full, "utf8")), mtime: mtimeMs(full) });
  }
  return out;
}

// ── SQLite open ──────────────────────────────────────────────────────────────

function openDb(dbPath: string): DbLike {
  const db = new Database(dbPath);
  db.pragma("foreign_keys = ON");
  return db;
}

function selectBrand(db: DbLike, domain?: string): Brand | null {
  if (domain) {
    const row = db.prepare("SELECT * FROM brands WHERE domain = ?").get(domain) as
      | Brand
      | undefined;
    if (row) return row;
  }
  // Fall back to the first brands row (a workdir is one brand).
  return (
    (db.prepare("SELECT * FROM brands ORDER BY fetched_at DESC LIMIT 1").get() as
      | Brand
      | undefined) ?? null
  );
}

function safeJsonParse<T>(s: string | null | undefined): T | null {
  if (!s) return null;
  try {
    return JSON.parse(s) as T;
  } catch {
    return null;
  }
}

// ── raw/*.json input shapes (subset we read) ─────────────────────────────────

interface CompanyJson {
  name?: string | null;
  description?: string | null;
  tagline?: string | null;
  industry?: string | null;
  founded?: number | string | null;
  city?: string | null;
  country?: string | null;
  naics?: string[];
  sic?: string[];
  employeeRange?: string | null;
  employeeCount?: number | null;
  revenue?: string | null;
  socials?: Record<string, string>;
}

interface TokensJson {
  palette?: {
    primary?: string | null;
    secondary?: string | null;
    accent?: string | null;
    neutrals?: string[];
    all?: string[];
  };
  fonts?: Array<{ family: string; dominance?: number | null; uses?: string[] }>;
  voice?: { name?: string | null; slogan?: string | null; description?: string | null };
}

interface LogoCandidateJson {
  url: string;
  source?: string;
  format?: "svg" | "png" | "jpg" | "unknown";
  confidence?: number;
}
interface LogoJson {
  domain?: string;
  candidates?: LogoCandidateJson[];
  recommended?: number;
}

interface BrandJson {
  brand?: Brand;
  extras?: { screenshot_url?: string | null; fonts?: Array<{ family: string }> };
}

interface PaletteVisionJson {
  analyses?: Array<{ palette?: string[] }>;
}

interface CreativeAnalysisJson {
  hook?: string;
  mood?: string;
  summary?: string;
  palette?: string[];
}
interface AdsVisionJson {
  analyses?: CreativeAnalysisJson[];
}

// ── palette union (≥6 gate) ──────────────────────────────────────────────────

const KNOWN_COLOR_NAMES: Record<string, string> = {};

function normHex(h: string): string | null {
  const m = h.trim().match(/^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/);
  if (!m) return null;
  let hex = (m[1] ?? "").toLowerCase();
  if (hex.length === 3)
    hex = hex
      .split("")
      .map((c) => c + c)
      .join("");
  return `#${hex}`;
}

/** Union palette from brands.palette_json + tokens.json + palette-vision.json. */
function unionPalette(
  brand: Brand | null,
  tokens: TokensJson | null,
  vision: PaletteVisionJson | null,
): Array<{ name: string; hex: string }> {
  const seen = new Set<string>();
  const out: Array<{ name: string; hex: string }> = [];
  const push = (raw: string) => {
    const hex = normHex(raw);
    if (!hex || seen.has(hex)) return;
    seen.add(hex);
    out.push({ name: KNOWN_COLOR_NAMES[hex] ?? `Color ${out.length + 1}`, hex });
  };
  const fromBrand = safeJsonParse<string[]>(brand?.palette_json ?? null) ?? [];
  for (const h of fromBrand) push(h);
  if (tokens?.palette) {
    if (tokens.palette.primary) push(tokens.palette.primary);
    if (tokens.palette.secondary) push(tokens.palette.secondary);
    if (tokens.palette.accent) push(tokens.palette.accent);
    for (const h of tokens.palette.all ?? []) push(h);
    for (const h of tokens.palette.neutrals ?? []) push(h);
  }
  for (const a of vision?.analyses ?? []) {
    for (const h of a.palette ?? []) push(h);
  }
  return out;
}

// ── price banding ────────────────────────────────────────────────────────────

function priceBand(priceCents: number | null): string {
  if (priceCents == null) return "unpriced";
  const d = priceCents / 100;
  if (d < 100) return "0-100";
  if (d < 200) return "100-200";
  if (d < 300) return "200-300";
  if (d < 400) return "300-400";
  return "400+";
}

// raw_json shapes vary by platform; pull common variant arrays defensively.
function csvFromRaw(raw: Record<string, unknown> | null, keys: string[]): string {
  if (!raw) return "";
  for (const k of keys) {
    const v = raw[k];
    if (Array.isArray(v) && v.length) {
      return v
        .map((x) =>
          typeof x === "string"
            ? x
            : ((x as Record<string, unknown>)?.title ??
              (x as Record<string, unknown>)?.value ??
              ""),
        )
        .filter(Boolean)
        .map((x) => oneLine(x))
        .join(",");
    }
    if (typeof v === "string" && v.trim()) return oneLine(v);
  }
  return "";
}

function categoryFromRaw(raw: Record<string, unknown> | null): { category: string; sub: string } {
  if (!raw) return { category: "Uncategorized", sub: "All" };
  const type = pick(raw, "product_type", "category", "type") as string | undefined;
  const cat = type && String(type).trim() ? oneLine(type) : "Uncategorized";
  // sub = first /-segment after the category, else "All"
  const parts = cat
    .split("/")
    .map((s) => s.trim())
    .filter(Boolean);
  return { category: parts[0] ?? "Uncategorized", sub: parts[1] ?? "All" };
}

// ── product row model ────────────────────────────────────────────────────────

interface ProductRow extends Product {
  images: string | null; // GROUP_CONCAT of product_images.url
}

interface RenderProduct {
  id: string;
  title: string;
  sku: string;
  priceCents: number | null;
  price: string;
  currency: string;
  images: string[];
  url: string;
  stock: string;
  sizes: string;
  colors: string[];
  materials: string;
  tags: string;
  category: string;
  subcategory: string;
  categoryPath: string;
  collection: string;
  priceBand: string;
  description: string;
}

function toRenderProduct(r: ProductRow): RenderProduct {
  const raw = safeJsonParse<Record<string, unknown>>(r.raw_json) ?? null;
  const { category, sub } = categoryFromRaw(raw);
  const colorsCsv = csvFromRaw(raw, ["colors", "color_options", "options_color", "variant_colors"]);
  const collection = csvFromRaw(raw, ["collection", "collections"]).split(",")[0] || category;
  // Dedupe images per product (preserving position order): the builder's
  // GROUP_CONCAT(pi.url) does not dedupe, so a product with a repeated row in
  // product_images would otherwise render the same image twice in :IMAGES:
  // (wb-syjo — the brand-scout manually deduped this every run).
  const images = [
    ...new Set(
      (r.images ?? "")
        .split(",")
        .map((u) => u.trim())
        .filter(Boolean),
    ),
  ];
  return {
    id: slugify(r.title || r.external_id || r.id),
    title: r.title,
    sku: r.external_id ?? "",
    priceCents: r.price_cents,
    price: r.price_cents != null ? String(r.price_cents / 100) : "",
    currency: r.currency ?? "",
    images,
    url: r.url,
    stock: r.available ? "in-stock" : "out-of-stock",
    sizes: csvFromRaw(raw, ["sizes", "size_options", "variant_sizes"]),
    colors: colorsCsv ? colorsCsv.split(",").filter(Boolean) : [],
    materials: csvFromRaw(raw, ["materials", "material"]),
    tags: csvFromRaw(raw, ["tags"]),
    category,
    subcategory: sub,
    categoryPath: `${category}/${sub}`,
    collection,
    priceBand: priceBand(r.price_cents),
    description: oneLine(r.description ?? ""),
  };
}

// ── FILE EMITTERS ─────────────────────────────────────────────────────────────

function emitBrandOrg(opts: {
  brand: Brand;
  slug: string;
  domain: string;
  utcIso: string;
  company: CompanyJson | null;
  tokens: TokensJson | null;
  vision: PaletteVisionJson | null;
  logo: LogoJson | null;
  brandJson: BrandJson | null;
}): string {
  const { brand, slug, domain, utcIso, company, tokens, vision, logo, brandJson } = opts;
  const name = brand.name ?? company?.name ?? slug;
  const firmographicsNull =
    !company ||
    (!company.industry && !company.founded && !company.revenue && !company.employeeCount);
  const status = firmographicsNull ? "needs_key" : "ok";

  const lines: string[] = [];
  lines.push(`#+TITLE: ${oneLine(name)} brand book`);
  lines.push(`#+GENERATED_AT: ${utcIso}`);
  lines.push(`#+GENERATED_BY: brandnana v${pkg.version}`);
  lines.push(`#+DOMAIN: ${domain}`);
  lines.push(`#+SLUG: ${slug}`);
  lines.push("");

  // * brand headline
  lines.push(
    `* ${oneLine(name)}                                                       :brand:point:`,
  );
  lines.push(
    propsDrawer(
      [
        ["ID", slug],
        ["DOMAIN", domain],
        ["LEGAL_NAME", company?.name ?? name],
        ["FOUNDED", company?.founded ?? ""],
        ["HQ", [company?.city, company?.country].filter(Boolean).join(", ")],
        ["CATEGORY", company?.industry ?? ""],
        ["TAGLINE", company?.tagline ?? tokens?.voice?.slogan ?? ""],
        ["STATUS", status],
        ["TOOL", "brand.fetch"],
      ],
      "  ",
    ),
  );
  lines.push("");

  // ** Voice
  lines.push("** Voice");
  const voice = oneLine(
    tokens?.voice?.description ?? company?.tagline ?? tokens?.voice?.slogan ?? "",
  );
  if (voice) lines.push(`   ${voice}`);
  lines.push("");

  lines.push("** Visual identity                                              :visual:");
  lines.push("");

  // *** Primary palette
  const palette = unionPalette(brand, tokens, vision);
  const primary = palette[0]?.hex ?? tokens?.palette?.primary ?? "";
  const secondary = palette[1]?.hex ?? tokens?.palette?.secondary ?? "";
  lines.push(
    "*** Primary palette                                            :palette:primary:point:",
  );
  lines.push(
    propsDrawer(
      [
        ["PRIMARY_HEX", primary],
        ["PRIMARY_NAME", palette[0]?.name ?? ""],
        ["SECONDARY_HEX", secondary],
        ["SECONDARY_NAME", palette[1]?.name ?? ""],
        ["STATUS", primary ? "ok" : "failed"],
        ["TOOL", "design.tokens"],
      ],
      "    ",
    ),
  );
  lines.push("");

  // *** Extended palette (≥6 gate)
  lines.push(
    "*** Extended palette                                           :palette:extended:point:",
  );
  lines.push(
    propsDrawer(
      [
        ["STATUS", palette.length >= 6 ? "ok" : "needs_key"],
        ["TOOL", "union+vision"],
      ],
      "    ",
    ),
  );
  for (const c of palette) lines.push(`    - ${c.name}: ${c.hex}`);
  if (palette.length === 0) lines.push("    (no palette swatches recovered)");
  lines.push("");

  // *** Typography
  const fonts = tokens?.fonts ?? [];
  const sortedFonts = [...fonts].sort((a, b) => (b.dominance ?? 0) - (a.dominance ?? 0));
  lines.push("*** Typography                                                 :fonts:point:");
  lines.push(
    propsDrawer(
      [
        ["PRIMARY_FONT", sortedFonts[0]?.family ?? brandJson?.extras?.fonts?.[0]?.family ?? ""],
        ["SECONDARY_FONT", sortedFonts[1]?.family ?? ""],
        ["MONO_FONT", sortedFonts.find((f) => /mono/i.test(f.family))?.family ?? ""],
        ["STATUS", sortedFonts.length > 0 ? "ok" : "needs_key"],
        ["TOOL", "context.dev/fonts"],
      ],
      "    ",
    ),
  );
  lines.push("");

  // *** Logo — recommended candidate's R2 URL. recommended=-1 (all rejected,
  // e.g. favicon-only) ⇒ no candidate. Never fall back to brand.logo_url, which
  // itself may be a favicon-grade pick; an honest gap beats a wrong logo. Only a
  // canonical R2 asset is emitted — a raw vendor URL is withheld (needs_mirror).
  const logoCand =
    logo?.candidates && typeof logo.recommended === "number" && logo.recommended >= 0
      ? logo.candidates[logo.recommended]
      : undefined;
  const logoMedia = resolveMediaUrl(logoCand?.url);
  lines.push("*** Logo                                                       :logo:point:");
  lines.push(
    propsDrawer(
      [
        ["PRIMARY_URL", logoMedia.url],
        ["SVG_PATH", logoCand?.format === "svg" && logoMedia.status === "ok" ? `./media/${slug}-logo.svg` : ""],
        ["STATUS", logoMedia.status],
        ["TOOL", "logo-cascade"],
      ],
      "    ",
    ),
  );
  if (logoMedia.note) lines.push(`    ${logoMedia.note}`);
  lines.push("");

  // *** Homepage screenshot — canonical R2 URL only; a raw context.dev /
  // media.brand.dev URL is withheld (needs_mirror), never hotlinked.
  const shotMedia = resolveMediaUrl(brandJson?.extras?.screenshot_url);
  lines.push("*** Homepage                                                   :screenshot:point:");
  lines.push(
    propsDrawer(
      [
        ["SCREENSHOT_URL", shotMedia.url],
        ["STATUS", shotMedia.status],
        ["TOOL", "context.dev/screenshot"],
      ],
      "    ",
    ),
  );
  if (shotMedia.note) lines.push(`    ${shotMedia.note}`);
  lines.push("");

  // ** Social handles
  lines.push("** Social handles                                              :social:point:");
  lines.push(
    propsDrawer(
      [
        ["STATUS", "ok"],
        ["TOOL", "brand.company"],
      ],
      "   ",
    ),
  );
  const socials = company?.socials ?? {};
  const socialEntries = Object.entries(socials);
  for (const [network, url] of socialEntries) {
    const handle = String(url).replace(/\/+$/, "").split("/").pop()?.replace(/^@/, "") ?? "";
    lines.push(`   - ${network}: ${handle} (${url})`);
  }
  if (socialEntries.length === 0) lines.push("   (no social handles discovered)");
  lines.push("");

  return `${lines.join("\n")}\n`;
}

function emitProductsOrg(opts: {
  brandName: string;
  utcIso: string;
  products: RenderProduct[];
  strategy: string;
}): string {
  const { brandName, utcIso, products, strategy } = opts;
  const categories = [...new Set(products.map((p) => p.category))];

  const lines: string[] = [];
  lines.push(`#+TITLE: ${oneLine(brandName)} product catalog`);
  lines.push(`#+GENERATED_AT: ${utcIso}`);
  lines.push(`#+PRODUCT_COUNT: ${products.length}`);
  lines.push(`#+CATEGORY_COUNT: ${categories.length}`);
  lines.push("");
  lines.push("* Catalog");
  lines.push("");

  // ── by-category (canonical :product:point: rows, level 5) ──
  lines.push("** by-category                                                 :index:category:");
  const byCat = new Map<string, Map<string, RenderProduct[]>>();
  for (const p of products) {
    let subs = byCat.get(p.category);
    if (!subs) {
      subs = new Map();
      byCat.set(p.category, subs);
    }
    groupPush(subs, p.subcategory, p);
  }
  for (const [cat, subs] of byCat) {
    lines.push(`*** ${cat}`);
    for (const [sub, prods] of subs) {
      lines.push(`**** ${sub}`);
      for (const p of prods) {
        lines.push(
          `***** ${oneLine(p.title)}                                                 :product:point:`,
        );
        lines.push(
          propsDrawer(
            [
              ["ID", p.id],
              ["SKU", p.sku],
              ["PRICE", p.price],
              ["CURRENCY", p.currency],
              ["SIZES", p.sizes],
              ["COLORS", p.colors.join(",")],
              ["IMAGES", p.images.join(",")],
              ["URL", p.url],
              ["STOCK", p.stock],
              ["MATERIALS", p.materials],
              ["TAGS", p.tags],
              ["CATEGORY", p.categoryPath],
              ["COLLECTION", p.collection],
              ["PRICE_BAND", p.priceBand],
              ["STATUS", "ok"],
              ["TOOL", `catalog.crawl:${strategy}`],
            ],
            "      ",
          ),
        );
        if (p.description) {
          lines.push("");
          lines.push(`      ${p.description}`);
        }
        lines.push("");
      }
    }
  }
  lines.push("");

  // ── by-collection (ref rows) ──
  lines.push("** by-collection                                               :index:collection:");
  const byCol = new Map<string, RenderProduct[]>();
  for (const p of products) groupPush(byCol, p.collection, p);
  for (const [col, prods] of byCol) {
    lines.push(`*** ${col}`);
    for (const p of prods)
      lines.push(
        `**** ${oneLine(p.title)} ([[id:${p.id}][see canonical]])               :product:ref:`,
      );
  }
  lines.push("");

  // ── by-color (explode COLORS) ──
  lines.push("** by-color                                                    :index:color:");
  const byColor = new Map<string, RenderProduct[]>();
  for (const p of products)
    for (const c of p.colors.length ? p.colors : ["Unspecified"]) groupPush(byColor, c, p);
  for (const [color, prods] of byColor) {
    lines.push(
      `*** ${color}                                                   :color:${slugify(color)}:`,
    );
    for (const p of prods)
      lines.push(
        `**** ${oneLine(p.title)} ([[id:${p.id}][see canonical]])               :product:ref:`,
      );
  }
  lines.push("");

  // ── by-price-band ──
  lines.push("** by-price-band                                               :index:price-band:");
  const bandOrder = ["0-100", "100-200", "200-300", "300-400", "400+", "unpriced"];
  const byBand = new Map<string, RenderProduct[]>();
  for (const p of products) groupPush(byBand, p.priceBand, p);
  for (const band of bandOrder) {
    const prods = byBand.get(band);
    if (!prods) continue;
    lines.push(`*** ${band}`);
    for (const p of prods)
      lines.push(
        `**** ${oneLine(p.title)} — $${p.price} ([[id:${p.id}][see canonical]]) :product:ref:`,
      );
  }
  lines.push("");

  // ── by-stock-status ──
  lines.push("** by-stock-status                                             :index:stock-status:");
  const byStock = new Map<string, RenderProduct[]>();
  for (const p of products) groupPush(byStock, p.stock, p);
  for (const [stock, prods] of byStock) {
    lines.push(`*** ${stock}`);
    for (const p of prods)
      lines.push(
        `**** ${oneLine(p.title)} ([[id:${p.id}][see canonical]])               :product:ref:`,
      );
  }
  lines.push("");

  return `${lines.join("\n")}\n`;
}

function emitSocialOrg(opts: {
  brandName: string;
  platform: string;
  profile: Record<string, unknown>;
  videos: unknown;
}): string {
  const { brandName, platform, profile, videos } = opts;
  const Platform = platform.charAt(0).toUpperCase() + platform.slice(1);

  // Field-map per-platform follower keys (TikTok / YouTube / IG differ).
  const stats = (pick(profile, "stats") as Record<string, unknown> | undefined) ?? {};
  const followers =
    pick(
      profile,
      "follower_count",
      "followers",
      "followerCount",
      "subscriberCount",
      "subscribers",
    ) ??
    pick(stats, "followerCount", "subscriberCount") ??
    "";
  const url = pick(profile, "url", "profile_url", "profileUrl", "link") ?? "";
  const handle =
    pick(profile, "handle", "username", "unique_id", "uniqueId") ??
    (typeof url === "string" ? url.replace(/\/+$/, "").split("/").pop()?.replace(/^@/, "") : "") ??
    "";
  const verified = pick(profile, "is_verified", "verified", "isVerified") ?? false;

  const lines: string[] = [];
  lines.push(`#+TITLE: ${oneLine(brandName)} — ${Platform}`);
  lines.push("");
  lines.push(
    `* ${Platform}                                                       :social:${platform}:point:`,
  );
  lines.push(
    propsDrawer(
      [
        ["FOLLOWERS", followers],
        ["HANDLE", handle],
        ["URL", url],
        ["VERIFIED", verified ? "t" : "f"],
        ["STATUS", followers !== "" ? "ok" : "needs_key"],
        ["TOOL", `social/${platform}`],
      ],
      "  ",
    ),
  );
  lines.push("");
  lines.push("** Top posts");

  // videos.json shape varies; pull an array of items with a thumbnail + caption + views.
  // Thumbnails are only emitted when mirrored to a canonical R2 asset — a raw
  // social-CDN thumb URL is a rot-prone hotlink, so it is withheld (the caption +
  // views still render). This keeps the social org free of unvalidated hotlinks.
  const items = extractVideoItems(videos);
  let withheldThumbs = 0;
  for (const it of items.slice(0, 10)) {
    const thumb = (it.thumb ?? "").trim();
    const caption = oneLine(it.caption ?? "");
    const views = it.views != null ? ` (${it.views})` : "";
    if (thumb && isR2Asset(thumb)) {
      lines.push(`   - ${thumb} — "${caption}"${views}`);
    } else {
      if (thumb) withheldThumbs++;
      lines.push(`   - (thumb needs_mirror) — "${caption}"${views}`);
    }
  }
  if (items.length === 0) lines.push("   (no top posts captured)");
  else if (withheldThumbs > 0)
    lines.push(`   note: ${withheldThumbs} thumbnail URL(s) withheld — run with --mirror`);
  lines.push("");

  return `${lines.join("\n")}\n`;
}

function extractVideoItems(
  videos: unknown,
): Array<{ thumb?: string; caption?: string; views?: number | string }> {
  const container =
    videos && typeof videos === "object" ? (videos as Record<string, unknown>) : null;
  const arr: unknown[] = Array.isArray(videos)
    ? videos
    : ((container
        ? (pick(container, "videos", "items", "data") as unknown[] | undefined)
        : undefined) ?? []);
  return arr
    .filter((v): v is Record<string, unknown> => !!v && typeof v === "object")
    .map((v) => ({
      thumb: pick(v, "thumb", "thumbnail", "cover", "thumbnail_url") as string | undefined,
      caption: pick(v, "caption", "title", "desc", "description") as string | undefined,
      views: pick(v, "views", "view_count", "playCount", "play_count") as
        | number
        | string
        | undefined,
    }));
}

interface AdRow {
  id: string;
  source: string;
  external_id: string;
  url: string | null;
  body: string | null;
  cta: string | null;
  first_seen_at: number;
  last_seen_at: number;
}

function emitAdsOrg(opts: {
  brandName: string;
  utcIso: string;
  ads: AdRow[];
  media: Map<string, string[]>; // ad_id → [media urls]
  vision: Map<string, CreativeAnalysisJson>; // external_id → analysis
  sourcesSeen: Set<string>;
}): string {
  const { brandName, utcIso, ads, media, vision, sourcesSeen } = opts;
  const lines: string[] = [];
  lines.push(`#+TITLE: ${oneLine(brandName)} — ads`);
  lines.push("");
  lines.push("* Ads");
  lines.push("");

  const sourcesWithAds = new Set<string>();
  for (const ad of ads) {
    sourcesWithAds.add(ad.source);
    const headline = oneLine(ad.body ?? ad.cta ?? ad.external_id).slice(0, 80) || "(untitled)";
    const mediaUrls = media.get(ad.id) ?? [];
    const an = vision.get(ad.external_id);
    lines.push(`** ${ad.source}: ${headline}                           :ad:${ad.source}:point:`);
    // ad_media URLs are written by `ads search --mirror` as canonical R2 assets.
    // An unmirrored vendor CDN URL is withheld (needs_mirror), never hotlinked.
    // No ad_media row at all ⇒ no creative captured for this ad ⇒ STATUS=ok with
    // an empty MEDIA_URL (a text/landing-only ad is a legitimate true-positive).
    const adMedia = resolveMediaUrl(mediaUrls[0]);
    const mediaStatus = mediaUrls.length === 0 ? "ok" : adMedia.status;
    lines.push(
      propsDrawer(
        [
          ["AD_ID", ad.external_id],
          ["MEDIA_URL", adMedia.url],
          ["CTA", ad.cta ?? ""],
          ["LANDING_URL", ad.url ?? ""],
          ["HOOK", an?.hook ?? ""],
          ["MOOD", an?.mood ?? ""],
          ["FIRST_SEEN", isoFromMs(ad.first_seen_at)],
          ["LAST_SEEN", isoFromMs(ad.last_seen_at)],
          ["STATUS", mediaStatus],
          ["TOOL", `scrape/${ad.source} + creative.analyze`],
        ],
        "   ",
      ),
    );
    if (mediaUrls.length > 0 && adMedia.note) lines.push(`   ${adMedia.note}`);
    const summary = oneLine(an?.summary ?? ad.body ?? "");
    if (summary) {
      lines.push("");
      lines.push(`   ${summary}`);
    }
    lines.push("");
  }

  // True-negative rows for searched sources that returned 0 ads.
  for (const src of sourcesSeen) {
    if (sourcesWithAds.has(src)) continue;
    lines.push(
      `** ${src.charAt(0).toUpperCase() + src.slice(1)}                                                    :ad:${src}:point:`,
    );
    lines.push(
      propsDrawer(
        [
          ["STATUS", "ok"],
          ["TOOL", `scrape/${src}`],
        ],
        "   ",
      ),
    );
    lines.push(`   No ${src} ad-library matches — true-negative (recorded, not retried).`);
    lines.push("");
  }

  return `${lines.join("\n")}\n`;
}

interface ProvPoint {
  point: string;
  status: "ok" | "failed" | "needs_key";
  tool: string;
  ts: string;
  durationMs: number | null;
  vendorCost: number | null;
  summary: string;
  error?: string;
}

function emitProvenanceOrg(opts: {
  brandName: string;
  utcIso: string;
  points: ProvPoint[];
}): string {
  const { brandName, utcIso, points } = opts;
  const lines: string[] = [];
  lines.push(`#+TITLE: ${oneLine(brandName)} brand-book capture timeline`);
  lines.push(`#+GENERATED_AT: ${utcIso}`);
  lines.push("");
  lines.push("* Capture log");
  lines.push("");
  // capture order = chronological by timestamp
  const ordered = [...points].sort((a, b) => a.ts.localeCompare(b.ts));
  for (const p of ordered) {
    lines.push(`** ${p.ts} — ${p.point}                    :event:${p.status}:point:`);
    lines.push(
      propsDrawer(
        [
          ["POINT", p.point],
          ["STATUS", p.status],
          ["TOOL", p.tool],
          ["DURATION_MS", p.durationMs ?? ""],
          ["VENDOR_COST", `$${(p.vendorCost ?? 0).toFixed(4)}`],
        ],
        "   ",
      ),
    );
    lines.push("");
    if (p.summary) lines.push(`   ${p.summary}`);
    if (p.error) {
      lines.push("");
      lines.push(`   ERROR: ${oneLine(p.error)}`);
    }
    lines.push("");
  }
  return `${lines.join("\n")}\n`;
}

// ── command ──────────────────────────────────────────────────────────────────

interface BuildOpts {
  db: string;
  domain?: string;
  out?: string;
}

export function registerSubstrate(program: Command): void {
  const substrate = program
    .command("substrate")
    .description("Deterministically render the OQL org substrate from a gather workdir");

  substrate
    .command("build [workdir]")
    .description(
      "Render brand.org / catalog/products.org / social/*.org / ads.org / harvest-provenance.org faithfully from the gather workdir (no LLM, no network)",
    )
    .option("--db <path>", "SQLite path relative to workdir", ".brandnana/brandnana.sqlite")
    .option("--domain <domain>", "Brand domain to render (defaults to the workdir's brands row)")
    .option("--out <dir>", "Output directory (defaults to the workdir itself)")
    .action((workdirArg: string | undefined, opts: BuildOpts) =>
      runAction(async () => {
        const workdir = resolve(process.cwd(), workdirArg ?? ".");
        const outDir = opts.out ? resolve(process.cwd(), opts.out) : workdir;
        const dbPath = resolve(workdir, opts.db);
        const utcIso = isoFromMs(Date.now());

        if (!existsSync(dbPath)) {
          throw new Error(
            `SQLite not found at ${dbPath} — is this a gather workdir? (run gather first)`,
          );
        }

        const rawDir = join(workdir, "raw");
        const socialDir = join(workdir, "social");
        const costs = loadCostFiles(workdir);

        // ── load raw/*.json inputs ──
        const company = readJsonIf<CompanyJson>(join(rawDir, "company.json"));
        const tokens = readJsonIf<TokensJson>(join(rawDir, "tokens.json"));
        const vision = readJsonIf<PaletteVisionJson>(join(rawDir, "palette-vision.json"));
        const logo = readJsonIf<LogoJson>(join(rawDir, "logo.json"));
        const brandJson = readJsonIf<BrandJson>(join(rawDir, "brand.json"));
        const crawlSummary = readJsonIf<{ strategy?: string; products?: number }>(
          join(workdir, "catalog", "crawl.json"),
        );

        const db = openDb(dbPath);
        const emitted: string[] = [];
        const provPoints: ProvPoint[] = [];
        let productCount = 0;
        let adCount = 0;
        const socialFiles: string[] = [];

        try {
          const brand = selectBrand(db, opts.domain);
          if (!brand) throw new Error("no brands row in SQLite — gather did not run `brand fetch`");
          const domain = brand.domain;
          const slug = slugFromDomain(domain);
          const brandName = brand.name ?? company?.name ?? slug;

          mkdirSync(outDir, { recursive: true });
          mkdirSync(join(outDir, "catalog"), { recursive: true });
          mkdirSync(join(outDir, "social"), { recursive: true });

          // ── brand.org ──
          writeFileSync(
            join(outDir, "brand.org"),
            emitBrandOrg({ brand, slug, domain, utcIso, company, tokens, vision, logo, brandJson }),
          );
          emitted.push(join(outDir, "brand.org"));

          // ── catalog/products.org — SQLite ONLY (every row) ──
          const productRows = db
            .prepare(
              `SELECT p.*,
                      (SELECT GROUP_CONCAT(pi.url, ',')
                         FROM product_images pi
                        WHERE pi.product_id = p.id
                        ORDER BY pi.position) AS images
                 FROM products p
                WHERE p.brand_id = ?
                ORDER BY p.title`,
            )
            .all(brand.id) as ProductRow[];
          const products = productRows.map(toRenderProduct);
          productCount = products.length;
          const strategy = crawlSummary?.strategy ?? "auto";
          writeFileSync(
            join(outDir, "catalog", "products.org"),
            emitProductsOrg({ brandName, utcIso, products, strategy }),
          );
          emitted.push(join(outDir, "catalog", "products.org"));
          progress(`catalog: ${productCount} products rendered from SQLite`);

          // ── social/<platform>.org — one per discovered profile ──
          if (existsSync(socialDir)) {
            const profileFiles = readdirSync(socialDir).filter((f) => /-profile\.json$/.test(f));
            for (const pf of profileFiles) {
              const platform = pf.replace(/-profile\.json$/, "");
              const profile = readJsonIf<Record<string, unknown>>(join(socialDir, pf));
              if (!profile) continue;
              const videos = readJsonIf<unknown>(join(socialDir, `${platform}-videos.json`));
              const target = join(outDir, "social", `${platform}.org`);
              writeFileSync(target, emitSocialOrg({ brandName, platform, profile, videos }));
              emitted.push(target);
              socialFiles.push(platform);
            }
          }

          // ── ads.org — SQLite ads + ad_media joined with creative vision ──
          const adRows = db
            .prepare(
              `SELECT id, source, external_id, url, body, cta, first_seen_at, last_seen_at
                 FROM ads
                ORDER BY source, first_seen_at`,
            )
            .all() as AdRow[];
          adCount = adRows.length;
          const mediaRows = db
            .prepare("SELECT ad_id, url FROM ad_media ORDER BY ad_id")
            .all() as Array<{ ad_id: string; url: string }>;
          const media = new Map<string, string[]>();
          for (const m of mediaRows) groupPush(media, m.ad_id, m.url);
          // creative vision: raw/ads-vision-*.json, keyed by external_id when present
          const visionMap = new Map<string, CreativeAnalysisJson>();
          const sourcesSeen = new Set<string>();
          if (existsSync(rawDir)) {
            for (const f of readdirSync(rawDir)) {
              if (/^ads-([a-z]+)\.json$/.test(f)) {
                const m = f.match(/^ads-([a-z]+)\.json$/);
                if (m?.[1]) sourcesSeen.add(m[1]);
              }
              if (/^ads-vision-.*\.json$/.test(f)) {
                const v = readJsonIf<AdsVisionJson>(join(rawDir, f));
                const id = f.replace(/^ads-vision-/, "").replace(/\.json$/, "");
                const an = v?.analyses?.[0];
                if (an) visionMap.set(id, an);
              }
            }
          }
          for (const ad of adRows) sourcesSeen.add(ad.source);
          writeFileSync(
            join(outDir, "ads.org"),
            emitAdsOrg({ brandName, utcIso, ads: adRows, media, vision: visionMap, sourcesSeen }),
          );
          emitted.push(join(outDir, "ads.org"));

          // ── harvest-provenance.org — real mtimes + costs ──
          // Map each captured artifact to a provenance point with a REAL timestamp.
          const point = (
            id: string,
            artifactPath: string,
            tool: string,
            costStem: string,
            summary: string,
            status: ProvPoint["status"] = "ok",
            error?: string,
          ) => {
            const mt = mtimeMs(artifactPath);
            if (mt == null && status === "ok") return; // artifact absent → not captured
            const c = costs.get(costStem);
            provPoints.push({
              point: id,
              status,
              tool,
              ts: isoFromMs(mt ?? c?.mtime ?? Date.now()),
              durationMs: null,
              vendorCost: c?.cost.usd_with_margin ?? null,
              summary,
              ...(error ? { error } : {}),
            });
          };

          point(
            "identity.brand",
            join(rawDir, "brand.json"),
            "brand.fetch",
            "brand_fetch",
            "logo + palette + fonts + screenshot",
          );
          point(
            "identity.logo",
            join(rawDir, "logo.json"),
            "logo-cascade",
            "logo_fetch",
            "logo cascade + alternates",
          );
          point(
            "identity.tokens",
            join(rawDir, "tokens.json"),
            "design.tokens",
            "design_tokens",
            "palette + fonts",
          );
          point(
            "identity.palette",
            join(rawDir, "palette-vision.json"),
            "union+vision",
            "creative_analyze",
            "vision palette fallback",
          );
          point(
            "company.firmographics",
            join(rawDir, "company.json"),
            "brand.company",
            "brand_company",
            `${Object.keys(company?.socials ?? {}).length} social URLs`,
            company && (company.industry || company.founded) ? "ok" : "needs_key",
            company && (company.industry || company.founded)
              ? undefined
              : "firmographics null — provider keyless (record needs_key, not green)",
          );
          {
            const dbMt = mtimeMs(dbPath);
            const c = costs.get("catalog_crawl");
            provPoints.push({
              point: "catalog",
              status: productCount > 0 ? "ok" : "failed",
              tool: `catalog.crawl:${strategy}`,
              ts: isoFromMs(dbMt ?? Date.now()),
              durationMs: null,
              vendorCost: c?.cost.usd_with_margin ?? null,
              summary: `${productCount} products · ${products.reduce((n, p) => n + p.images.length, 0)} images mirrored to R2`,
              ...(productCount === 0 ? { error: "catalog crawl returned 0 products" } : {}),
            });
          }
          for (const platform of socialFiles) {
            point(
              `social.${platform}`,
              join(socialDir, `${platform}-profile.json`),
              `social/${platform}`,
              "social",
              `${platform} profile + top posts`,
            );
          }
          if (existsSync(rawDir)) {
            for (const f of readdirSync(rawDir)) {
              const m = f.match(/^ads-([a-z]+)\.json$/);
              if (m?.[1]) {
                const src = m[1];
                const n = adRows.filter((a) => a.source === src).length;
                point(
                  `ads.${src}`,
                  join(rawDir, f),
                  `scrape/${src}`,
                  "ads_search",
                  n > 0 ? `${n} creatives` : "0 results — verified true-negative",
                );
              }
            }
          }

          writeFileSync(
            join(outDir, "harvest-provenance.org"),
            emitProvenanceOrg({ brandName, utcIso, points: provPoints }),
          );
          emitted.push(join(outDir, "harvest-provenance.org"));
        } finally {
          db.close();
        }

        emit(
          {
            workdir,
            out: outDir,
            files: emitted,
            products: productCount,
            ads: adCount,
            social_platforms: socialFiles,
            provenance_points: provPoints.length,
          },
          [
            `substrate rendered → ${outDir}`,
            "  brand.org",
            `  catalog/products.org   (${productCount} products from SQLite)`,
            ...socialFiles.map((p) => `  social/${p}.org`),
            `  ads.org                (${adCount} ads)`,
            `  harvest-provenance.org (${provPoints.length} points)`,
          ].join("\n"),
        );
      }),
    );
}
