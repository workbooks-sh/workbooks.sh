#!/usr/bin/env node
// Lesson icon generator — recraft v4.1 vector via OpenRouter, returns raw SVG.
// THE STYLE (diagnosed from wb-file / nexus / toolkit marks): one solid black
// silhouette per icon, soft organic rounded edges (hand-set, not geometric),
// all interior modeling done by NEGATIVE SPACE cutouts that imply depth and
// dimension — flat ink, dimensional reading. No outlines, strokes, gradients,
// or grays. Must read at 22px in the nav.
// Idempotent: skips existing files. Usage: OPENROUTER_API_KEY=… node generate.mjs [name …]

import { writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const KEY = process.env.OPENROUTER_API_KEY;
if (!KEY) { console.error("OPENROUTER_API_KEY not set"); process.exit(1); }
mkdirSync(HERE, { recursive: true });

const STYLE =
  "Abstract brand mark, NOT a pictogram: one EXTREMELY CHUNKY solid pure-black mass on a transparent background. " +
  "Heavy rounded organic forms with slightly hand-drawn warmth, like a modernist logo. " +
  "Interior detail is ONLY a few THICK white negative-space channels carved through the mass, implying depth and facets. " +
  "Radical simplification: at most 2 or 3 big shapes, zero fine detail, no thin lines, no human figures. " +
  "No outlines, no strokes, no gradients, no grays, no background. Centered, generous margins, reads at 20 pixels. ";

const ICONS = {
  // tier-2 lesson marks (replacing the ✳ ✦ ❀ >_ placeholder glyphs)
  "org":      "A thick rounded asterisk-star whose six lobes are carved apart by thick white channels, like a seed of branching structure.",
  "agents":   "A chunky four-pointed compass spark: one heavy rounded star form split by thick white channels into facets, suggesting a crew moving with purpose.",
  "autopoet": "One fat rounded watering can in profile, a single recognizable garden watering can: chunky body, thick curved spout, big rounded handle as a negative-space hole.",
  "work":      "A single bold right-pointing chevron symbol, like a giant play prompt, made of two thick rounded bars meeting at a point, with one clean white channel separating them.",
  // future tier-2 lessons
  "workflows": "Three fat rounded squares arranged in a diagonal staircase, overlapping at the corners where thick white channels separate them, a board in motion.",
  "vfs":      "One chunky rounded document page shape with a folded corner, carved by three thick white horizontal slots like drawers inside the page.",
};

async function gen(name, subject) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    const r = await fetch("https://openrouter.ai/api/v1/images/generations", {
      method: "POST",
      headers: { Authorization: "Bearer " + KEY, "content-type": "application/json" },
      body: JSON.stringify({ model: "recraft/recraft-v4.1-vector", prompt: STYLE + subject, n: 1 }),
    });
    if (r.ok) {
      const d = await r.json();
      const svg = Buffer.from(d.data[0].b64_json, "base64").toString("utf8");
      if (!svg.startsWith("<svg")) throw new Error("not svg: " + svg.slice(0, 60));
      return svg;
    }
    if (r.status === 429 || r.status >= 500) { await new Promise((s) => setTimeout(s, attempt * 15000)); continue; }
    throw new Error(r.status + ": " + (await r.text()).slice(0, 200));
  }
  throw new Error("gave up: " + name);
}

const only = process.argv.slice(2);
for (const [name, subject] of Object.entries(ICONS)) {
  if (only.length && !only.includes(name)) continue;
  const out = join(HERE, name + ".svg");
  if (existsSync(out)) continue;
  process.stdout.write(name + " … ");
  writeFileSync(out, await gen(name, subject));
  console.log("ok");
}
console.log("icons done");
