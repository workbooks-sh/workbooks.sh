#!/usr/bin/env node
/*!
 * build-curated.mjs — regenerate glyphs' curated JSON packs from live sources.
 *
 * Writes three files into packs/:
 *   - svgl-index.json     name(lowercase) -> route url (light picked). The whole
 *                         svgl catalog as a name→route map, so brand: long-tail
 *                         resolution at runtime is ONE fetch of the svg (no index
 *                         round-trip).
 *   - curated-brands.json name -> inlined full-color SVG string. The marks bit.ml
 *                         + the lander use. svgl first, simple-icons fallback.
 *   - curated-icons.json  name -> inlined currentColor SVG string (simple-icons).
 *
 * Zero deps. Node 18+ (global fetch). Run from anywhere:
 *   node scripts/build-curated.mjs
 *
 * The inlined SVGs are committed so the common marks are instant + offline. The
 * long tail resolves via the CDN at runtime through glyphAsync().
 */
import { writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PACKS = join(__dirname, "..", "packs");
mkdirSync(PACKS, { recursive: true });

const SVGL_INDEX = "https://api.svgl.app";
const SIMPLE = (slug) =>
  `https://cdn.jsdelivr.net/npm/simple-icons@latest/icons/${slug}.svg`;

// Curated brands — the marks bit.ml + the lander use. Each entry: the glyph
// name (the brand:<name> id), an optional svgl title to match in the index, and
// a simple-icons slug fallback. deepmind aliases to google.
const BRANDS = [
  { name: "google", svgl: "Google", si: "google" },
  { name: "nvidia", svgl: "NVIDIA", si: "nvidia" },
  { name: "tsmc", svgl: "TSMC", si: null },
  { name: "anthropic", svgl: "Anthropic", si: "anthropic" },
  { name: "openai", svgl: "OpenAI", si: "openai" },
  { name: "deepmind", svgl: "Google DeepMind", si: "googlegemini" },
  { name: "micron", svgl: "Micron", si: null },
  { name: "intel", svgl: "Intel", si: "intel" },
  { name: "amazon", svgl: "Amazon", si: "amazon" },
  { name: "apple", svgl: "Apple", si: "apple" },
  { name: "microsoft", svgl: "Microsoft", si: null },
  { name: "meta", svgl: "Meta", si: "meta" },
  { name: "cloudflare", svgl: "Cloudflare", si: "cloudflare" },
  { name: "github", svgl: "GitHub", si: "github" },
  { name: "vercel", svgl: "Vercel", si: "vercel" },
  { name: "x", svgl: "X", si: "x" },
  { name: "twitter", svgl: "X", si: "x" },
  { name: "bloomberg", svgl: "Bloomberg", si: null },
];

// Curated icons — from simple-icons (currentColor monochrome).
const ICONS = [
  ["html5", "html5"],
  ["css3", "css3"],
  ["javascript", "javascript"],
  ["typescript", "typescript"],
  ["react", "react"],
  ["vue", "vuedotjs"],
  ["svelte", "svelte"],
  ["elixir", "elixir"],
  ["rust", "rust"],
  ["python", "python"],
  ["nodejs", "nodedotjs"],
  ["go", "go"],
  ["docker", "docker"],
  ["git", "git"],
  ["tailwindcss", "tailwindcss"],
  ["postgresql", "postgresql"],
];

async function getText(url) {
  const r = await fetch(url, { redirect: "follow" });
  if (!r.ok) throw new Error(`${r.status} ${url}`);
  return (await r.text()).trim();
}

// route may be a string or { light, dark } — always pick light.
function pickRoute(route) {
  if (!route) return null;
  if (typeof route === "string") return route;
  return route.light || route.dark || null;
}

function looksLikeSvg(s) {
  return typeof s === "string" && /^<svg[\s>]/.test(s.trim());
}

async function main() {
  // 1. svgl index → name(lowercase) -> light route
  console.log("fetching svgl index…");
  const index = await (await fetch(SVGL_INDEX)).json();
  const indexMap = {};
  const byTitle = {};
  for (const row of index) {
    const route = pickRoute(row.route);
    if (!route || !row.title) continue;
    const key = String(row.title).toLowerCase();
    indexMap[key] = route;
    byTitle[row.title] = route;
  }
  writeFileSync(
    join(PACKS, "svgl-index.json"),
    JSON.stringify(indexMap, null, 0) + "\n"
  );
  console.log(`  svgl-index.json: ${Object.keys(indexMap).length} routes`);

  // 2. curated brands — svgl full-color first, simple-icons fallback.
  const brands = {};
  for (const b of BRANDS) {
    let svg = null;
    const route = (b.svgl && byTitle[b.svgl]) || indexMap[b.name];
    if (route) {
      try {
        svg = await getText(route);
      } catch (e) {
        console.warn(`  ! svgl ${b.name}: ${e.message}`);
      }
    }
    if (!looksLikeSvg(svg) && b.si) {
      try {
        svg = await getText(SIMPLE(b.si));
        console.log(`  ${b.name}: simple-icons fallback`);
      } catch (e) {
        console.warn(`  ! simple-icons ${b.name}: ${e.message}`);
      }
    }
    if (looksLikeSvg(svg)) {
      brands[b.name] = normalize(svg);
      console.log(`  brand ${b.name}: ${brands[b.name].length}b`);
    } else {
      console.warn(`  ✗ brand ${b.name}: no source`);
    }
  }
  writeFileSync(
    join(PACKS, "curated-brands.json"),
    JSON.stringify(brands, null, 0) + "\n"
  );
  console.log(`  curated-brands.json: ${Object.keys(brands).length} brands`);

  // 3. curated icons — simple-icons (currentColor).
  const icons = {};
  for (const [name, slug] of ICONS) {
    try {
      const svg = await getText(SIMPLE(slug));
      if (looksLikeSvg(svg)) {
        icons[name] = normalize(svg);
        console.log(`  icon ${name}: ${icons[name].length}b`);
      }
    } catch (e) {
      console.warn(`  ! icon ${name}: ${e.message}`);
    }
  }
  writeFileSync(
    join(PACKS, "curated-icons.json"),
    JSON.stringify(icons, null, 0) + "\n"
  );
  console.log(`  curated-icons.json: ${Object.keys(icons).length} icons`);
}

// Strip XML prolog / comments / leading-trailing whitespace; collapse newlines
// so the inlined string is one tidy line. Keeps the SVG verbatim otherwise.
function normalize(svg) {
  return svg
    .replace(/<\?xml[^>]*\?>/g, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/>\s+</g, "><")
    .replace(/\s+/g, " ")
    .replace(/<svg /, "<svg ")
    .trim();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
