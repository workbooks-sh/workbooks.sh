#!/usr/bin/env node
// Raster→vector icon pipeline: gemini-3-pro-image renders the icon in the
// house style WITH the three reference marks attached (raster models follow
// style references; the vector model couldn't) → potrace traces the solid
// shapes into a clean SVG. Strongest of both worlds.
// Usage: GEMINI_API_KEY=… node raster.mjs [name …]    (writes <name>.svg)

import { writeFileSync, readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const HERE = dirname(fileURLToPath(import.meta.url));
const KEY = process.env.GEMINI_API_KEY;
if (!KEY) { console.error("GEMINI_API_KEY not set"); process.exit(1); }

const REFS = ["wb-file-icon", "nexus-icon", "toolkit-icon"].map((n) => {
  // black-filled renders of the reference marks (white-filled sources)
  const svg = readFileSync(join(HERE, "..", "..", n + ".svg"), "utf8").replace(/fill="[^"]*"/g, 'fill="black"');
  const tmp = join("/tmp", n + "-ref.svg");
  writeFileSync(tmp, svg);
  execFileSync("rsvg-convert", ["-w", "512", tmp, "-o", tmp + ".png"]);
  return readFileSync(tmp + ".png").toString("base64");
});

const STYLE =
  "Design ONE new icon in EXACTLY the same style as the three attached reference icons: " +
  "a single chunky solid pure-black mass with heavy rounded organic forms, where the only interior " +
  "detail is a few THICK white negative-space channels carved through the mass to imply depth and facets. " +
  "Slightly hand-drawn modernist-logo warmth, never geometric-perfect, no thin lines, no outlines, no gray, " +
  "no shading. Render it large and centered on a pure white background, square image. Subject: ";

const ICONS = {
  org:       "a thick rounded six-lobed asterisk, the seed of branching structure.",
  agents:    "a small friendly robot head in profile: rounded helmet dome, one negative-space eye, a thick antenna nub.",
  autopoet:  "a garden watering can in profile: chunky body, thick curved spout, big rounded handle as a negative-space hole.",
  work:       "a bold terminal prompt: one massive right-pointing chevron with a low fat underscore block to its right.",
  workflows: "three fat rounded cards in a diagonal cascade, separated by thick white channels, a board in motion.",
  vfs:       "a chunky document page with a folded corner, carved by three thick horizontal drawer slots.",
};

async function render(subject) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    const r = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro-image:generateContent?key=${KEY}`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          contents: [{
            parts: [
              ...REFS.map((data) => ({ inline_data: { mime_type: "image/png", data } })),
              { text: STYLE + subject },
            ],
          }],
        }),
      }
    );
    if (r.ok) {
      const d = await r.json();
      const img = (d.candidates?.[0]?.content?.parts || []).find((p) => p.inlineData || p.inline_data);
      if (img) return Buffer.from((img.inlineData || img.inline_data).data, "base64");
      throw new Error("no image in response: " + JSON.stringify(d).slice(0, 200));
    }
    if (r.status === 429 || r.status >= 500) { await new Promise((s) => setTimeout(s, attempt * 15000)); continue; }
    throw new Error(r.status + ": " + (await r.text()).slice(0, 200));
  }
  throw new Error("gave up");
}

const only = process.argv.slice(2);
for (const [name, subject] of Object.entries(ICONS)) {
  if (only.length && !only.includes(name)) continue;
  const out = join(HERE, name + ".svg");
  if (existsSync(out) && !only.length) continue;
  process.stdout.write(name + " … ");
  const png = join("/tmp", "icon-" + name + ".png");
  writeFileSync(png, await render(subject));
  // threshold to clean 1-bit, then trace: solid shapes → smooth vector paths
  execFileSync("magick", [png, "-colorspace", "Gray", "-threshold", "55%", png + ".pbm"]);
  execFileSync("potrace", [png + ".pbm", "-s", "-o", out, "--flat", "-t", "12", "-O", "0.6"]);
  console.log("ok");
}
console.log("raster→vector done");
