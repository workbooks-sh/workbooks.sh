#!/usr/bin/env node
// Hero art generator — gemini-3-pro-image, retrofuturism canon.
// For each learn page missing img/<slug>-hero.jpg: the hero <img> alt text is
// the subject brief; append the canon style block + page-palette words.
// Idempotent: skips existing jpgs. Usage: GEMINI_API_KEY=… node gen-heroes.mjs [slug …]

import { readFileSync, writeFileSync, readdirSync, existsSync, unlinkSync } from "node:fs";
import { execSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const LEARN = join(HERE, "..");
const KEY = process.env.GEMINI_API_KEY;
if (!KEY) { console.error("GEMINI_API_KEY not set"); process.exit(1); }

const CANON = `1970s retrofuturist science-fiction illustration in the spirit of French sci-fi comic masters like Moebius and 70s airbrush poster art: fine clean ink linework, forms modeled with soft airbrushed gradients and gentle volumetric shading, dimensional and calm, rich print grain and subtle vintage paper texture, saturated but refined limited palette, small figures against monumental forms, generous luminous sky with empty space. Bright and light — no nighttime, no dark background. Not flat vector art, not screen-print, no photorealism, no 3D render, no text or lettering.`;

// pastel hex → palette words for the prompt
const PAL = {
  "#a8d4f0": "cream, pale sky blue, deep cobalt, and near-black ink",
  "#9fc4e8": "cream, pale sky blue, deep cobalt, and near-black ink",
  "#aee5c2": "cream, pale mint, deep leaf green, and near-black ink",
  "#f3c5a3": "cream, pale peach, burnt orange, brick red, and near-black ink",
  "#f2ddb0": "cream, warm sand, amber gold, and near-black ink",
  "#e8c9e0": "cream, pale lilac, deep plum, and near-black ink",
  "#f0b8b8": "cream, pale rose, warm coral red, and near-black ink",
  "#c5b8e8": "cream, pale lavender, deep violet, and near-black ink",
  "#b8e0e8": "cream, pale aqua, deep teal, and near-black ink",
};
const palWords = (hex) =>
  PAL[(hex || "").toLowerCase()] || "cream, soft pastels, one deep accent, and near-black ink";

const only = process.argv.slice(2);
const slugs = (only.length ? only : readdirSync(LEARN).filter((f) => f.endsWith(".html")).map((f) => f.slice(0, -5)))
  .filter((s) => !existsSync(join(HERE, `${s}-hero.jpg`)));

async function gen(prompt, outPng) {
  for (let attempt = 1; attempt <= 4; attempt++) {
    const r = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro-image:generateContent?key=${KEY}`,
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          contents: [{ role: "user", parts: [{ text: prompt }] }],
          generationConfig: { responseModalities: ["IMAGE", "TEXT"], imageConfig: { aspectRatio: "4:5", imageSize: "1K" } },
        }),
      }
    );
    if (r.ok) {
      const d = await r.json();
      const part = (d.candidates?.[0]?.content?.parts || []).find((p) => p.inlineData);
      if (part) { writeFileSync(outPng, Buffer.from(part.inlineData.data, "base64")); return true; }
      console.error("  no image in response — retrying");
    } else if (r.status === 429 || r.status >= 500) {
      await new Promise((s) => setTimeout(s, attempt * 20000));
      continue;
    } else {
      console.error(`  ${r.status}: ${(await r.text()).slice(0, 200)}`);
      return false;
    }
  }
  return false;
}

let made = 0, failed = [];
for (const slug of slugs) {
  const page = join(LEARN, `${slug}.html`);
  if (!existsSync(page)) continue;
  const html = readFileSync(page, "utf8");
  const alt = (html.match(new RegExp(`<img[^>]*src="img/${slug}-hero\\.jpg"[^>]*alt="([^"]+)"`)) ||
               html.match(new RegExp(`<img[^>]*alt="([^"]+)"[^>]*src="img/${slug}-hero\\.jpg"`)) || [])[1];
  if (!alt) { console.error(`${slug}: no hero img alt — skipped`); failed.push(slug); continue; }
  const pc = (html.match(/--pc:\s*(#[0-9a-fA-F]{6})/) || [])[1];
  const prompt = `${alt.replace(/&amp;/g, "&").replace(/&quot;/g, "")}. Limited palette of ${palWords(pc)}. ${CANON}`;
  process.stdout.write(`${slug} … `);
  const png = join(HERE, `${slug}-hero.png`);
  if (await gen(prompt, png)) {
    execSync(`magick "${png}" -resize 1000x -quality 74 "${join(HERE, `${slug}-hero.jpg`)}" && rm -f "${png}"`);
    console.log("ok");
    made++;
  } else { console.log("FAILED"); failed.push(slug); }
}
console.log(`heroes done — ${made} generated, failed: ${failed.length ? failed.join(" ") : "none"}`);
