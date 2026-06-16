#!/usr/bin/env node
// bundle-pack.mjs — compile an avatar pack into a single pure JSON bundle.
//
//   node scripts/bundle-pack.mjs <pack>        (default: open-peeps)
//
// Routes by pack.json `type`:
//
//   assembled (default)  reads atoms/<cat>/*.svg, strips each to its inner
//                        drawable group, emits pack.bundle.json:
//                          { ...pack.json, atoms: { <cat>: { "<Name>": "<inner>" } } }
//
//   gallery + kind:svg   reads <dir>/*.svg (whole-figure characters), strips each
//                        to its inner drawable, emits pack.bundle.json:
//                          { ...pack.json, items: { "<id>": "<inner svg>" } }
//
//   gallery + kind:raster
//                        reads the pack's manifest.json id list and emits a TINY
//                        ids file (default pixabots.ids.json):
//                          { ...pack.json, ids: [ "<id>", … ] }
//                        The 2000 rasters are NOT inlined — avatar() returns an
//                        <img> whose src is opts.base + the path template.
//
//   procedural           nothing to bundle (the pack ships generate.js); the
//                        pack.json IS the bundle. We still copy it to
//                        pack.bundle.json for a uniform "register a JSON" path.
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

// Strip an SVG document down to its inner drawable content: drop the <?xml>
// prolog, the Sketch/Figma generator comment, <title>/<desc>, and the root
// <svg …>…</svg> wrapper, keeping what's between the root tags. An atom that
// draws nothing (a lone empty <g></g>, the "* None" option) normalizes to "".
function innerOf(svgText) {
  let s = svgText
    .replace(/<\?xml[\s\S]*?\?>/g, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<title>[\s\S]*?<\/title>/gi, "")
    .replace(/<desc>[\s\S]*?<\/desc>/gi, "");
  const open = s.search(/<svg\b[^>]*>/i);
  if (open === -1) return "";
  const afterOpen = s.slice(s.indexOf(">", open) + 1);
  const close = afterOpen.lastIndexOf("</svg>");
  const inner = (close === -1 ? afterOpen : afterOpen.slice(0, close)).trim();
  if (/^<g\b[^>]*>\s*<\/g>$/.test(inner)) return "";
  return inner;
}

const type = meta.type || "assembled";

if (type === "assembled") {
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
    `bundled ${pack} (assembled): ${count} atoms across ${Object.keys(meta.categories).length} categories → ${outPath} (${(bytes / 1024).toFixed(1)} KB)`
  );
} else if (type === "gallery" && meta.kind === "svg") {
  const dir = join(packDir, meta.dir || "figures");
  if (!existsSync(dir)) {
    console.error(`gallery dir missing: ${dir}`);
    process.exit(1);
  }
  const items = {};
  const files = readdirSync(dir)
    .filter((f) => f.toLowerCase().endsWith(".svg"))
    .sort();
  for (const f of files) {
    const id = f.replace(/\.svg$/i, "");
    items[id] = innerOf(readFileSync(join(dir, f), "utf8"));
  }
  const bundle = { ...meta, items };
  const outPath = join(packDir, "pack.bundle.json");
  writeFileSync(outPath, JSON.stringify(bundle));
  const bytes = Buffer.byteLength(JSON.stringify(bundle));
  console.log(
    `bundled ${pack} (gallery/svg): ${files.length} figures → ${outPath} (${(bytes / 1024).toFixed(1)} KB)`
  );
} else if (type === "gallery" && meta.kind === "raster") {
  // Do NOT inline the rasters. Record just the id list (tiny) so avatar() can
  // pick one by seed and emit an <img src=base+path>.
  const manifestPath = join(packDir, "manifest.json");
  let ids;
  if (existsSync(manifestPath)) {
    const m = JSON.parse(readFileSync(manifestPath, "utf8"));
    ids = (m.ids || []).slice();
  } else {
    // Fall back to listing the asset dir.
    const base = (meta.base || "").replace(/\/$/, "");
    const dir = join(packDir, base);
    const ext = (meta.path || "<id>").replace(/^.*<id>/, "");
    ids = readdirSync(dir)
      .filter((f) => f.endsWith(ext))
      .map((f) => f.slice(0, f.length - ext.length));
  }
  ids.sort();
  // The tiny "bundle" the renderer registers: pack.json + the id list.
  const idsBundle = { ...meta, ids };
  const idsFile = meta.idsFile || `${pack}.ids.json`;
  const outPath = join(packDir, idsFile);
  writeFileSync(outPath, JSON.stringify(idsBundle));
  const bytes = Buffer.byteLength(JSON.stringify(idsBundle));
  console.log(
    `bundled ${pack} (gallery/raster): ${ids.length} ids → ${outPath} (${(bytes / 1024).toFixed(1)} KB, rasters NOT inlined)`
  );
} else if (type === "procedural") {
  // The pack.json is the bundle; generate.js is loaded separately and attached
  // as pack.generate by the consumer. Copy pack.json → pack.bundle.json.
  const outPath = join(packDir, "pack.bundle.json");
  writeFileSync(outPath, JSON.stringify(meta));
  console.log(`bundled ${pack} (procedural): pack.json → ${outPath} (generate.js shipped separately)`);
} else {
  console.error(`unknown pack type/kind: type=${meta.type} kind=${meta.kind}`);
  process.exit(1);
}
