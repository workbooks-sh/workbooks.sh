#!/usr/bin/env node
// bundle-pack.mjs — compile an avatar pack into a single pure JSON bundle.
//
//   node scripts/bundle-pack.mjs <pack>        (default: open-peeps)
//
// Reads packs/<pack>/pack.json + packs/<pack>/atoms/<cat>/*.svg, strips every
// atom down to its inner drawable group(s) (no <?xml>, no Sketch <!--Generator-->,
// no <title>/<desc>, no root <svg>), and emits packs/<pack>/pack.bundle.json:
//
//   { ...pack.json, atoms: { <cat>: { "<Name>": "<inner svg string>", ... } } }
//
// The bundle is what dist/open-avatars.js consumes — so avatar() is pure
// string→string with no fs, and runs unchanged in the wasm JS lane.
//
// Zero dependencies. Node only at BUILD time (this script); never at render time.

import { readFileSync, writeFileSync, readdirSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, "..");

const pack = process.argv[2] || "open-peeps";
const packDir = join(ROOT, "packs", pack);
const packJsonPath = join(packDir, "pack.json");

if (!existsSync(packJsonPath)) {
  console.error(`No pack.json at ${packJsonPath}`);
  process.exit(1);
}

const meta = JSON.parse(readFileSync(packJsonPath, "utf8"));

// Strip a Sketch-exported atom SVG down to its inner drawable content.
// The root <svg ...>…</svg> wraps the drawables; we keep what's between the
// root tags and drop the metadata cruft. "None" atoms have an empty group and
// legitimately produce "" — that is the empty option, not an error.
function innerOf(svgText) {
  let s = svgText
    .replace(/<\?xml[\s\S]*?\?>/g, "")
    .replace(/<!--[\s\S]*?-->/g, "") // Sketch generator comment
    .replace(/<title>[\s\S]*?<\/title>/gi, "")
    .replace(/<desc>[\s\S]*?<\/desc>/gi, "");
  // Grab everything inside the OUTER <svg …> … </svg>.
  const open = s.search(/<svg\b[^>]*>/i);
  if (open === -1) return "";
  const afterOpen = s.slice(s.indexOf(">", open) + 1);
  const close = afterOpen.lastIndexOf("</svg>");
  const inner = (close === -1 ? afterOpen : afterOpen.slice(0, close)).trim();
  // An atom that draws nothing — a lone empty group like the "* None" option —
  // normalizes to "" so it is a true empty pick (no hollow <g> in the output).
  if (/^<g\b[^>]*>\s*<\/g>$/.test(inner)) return "";
  return inner;
}

const atoms = {};
let count = 0;
for (const [cat, def] of Object.entries(meta.categories)) {
  const dir = join(packDir, def.dir);
  if (!existsSync(dir)) {
    console.error(`category dir missing: ${dir}`);
    process.exit(1);
  }
  atoms[cat] = {};
  const files = readdirSync(dir)
    .filter((f) => f.toLowerCase().endsWith(".svg"))
    .sort();
  for (const f of files) {
    const name = f.replace(/\.svg$/i, "");
    atoms[cat][name] = innerOf(readFileSync(join(dir, f), "utf8"));
    count++;
  }
}

const bundle = { ...meta, atoms };
const outPath = join(packDir, "pack.bundle.json");
writeFileSync(outPath, JSON.stringify(bundle));

const bytes = Buffer.byteLength(JSON.stringify(bundle));
console.log(
  `bundled ${pack}: ${count} atoms across ${Object.keys(meta.categories).length} categories → ${outPath} (${(bytes / 1024).toFixed(1)} KB)`
);
