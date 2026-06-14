#!/usr/bin/env node
// Blog hero art — gemini-3-pro-image, the same retrofuturism canon as the learn
// heroes (web/learn/img/gen-heroes.mjs). For each post in posts.json missing
// img/<slug>.jpg: subject = the post's `hero` brief (falls back to title+dek);
// append the canon style block. Idempotent. 16:9 for blog cards.
// Usage: GEMINI_API_KEY=… node gen-blog-heroes.mjs [slug …]
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { execSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const KEY = process.env.GEMINI_API_KEY;
if (!KEY) { console.error("GEMINI_API_KEY not set"); process.exit(1); }
mkdirSync(join(HERE, "img"), { recursive: true });

const CANON = `1970s retrofuturist science-fiction illustration in the spirit of French sci-fi comic masters and 70s airbrush poster art: fine clean ink linework, forms modeled with soft airbrushed gradients and gentle volumetric shading, dimensional and calm, rich print grain and subtle vintage paper texture, a refined limited palette of cream, sage green, deep forest green and near-black ink, small figures against monumental forms, generous luminous sky. Bright and light — no nighttime, no dark background. Not flat vector, not screen-print, no photorealism, no 3D render, no text or lettering.`;

const HERO = {
  "the-wall-is-coming-down": "a vast wall between two figures dissolving into light as one hands the other a small glowing object across the gap",
  "your-secrets-never-touch-the-os": "a small glowing vault sealed inside a translucent protective sphere while a helper figure works just outside it, unable to reach in",
  "software-you-can-hold": "a lone figure on a bright plain holding up a single luminous file-object that contains a whole tiny world inside it",
};

const posts = (() => { const d = JSON.parse(readFileSync(join(HERE, "posts.json"), "utf8")); return Array.isArray(d) ? d : (d.posts || []); })();
const only = process.argv.slice(2);
const todo = posts.filter(p => (!only.length || only.includes(p.slug)) && !existsSync(join(HERE, "img", `${p.slug}.jpg`)));

async function gen(prompt, out) {
  for (let a = 1; a <= 4; a++) {
    const r = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro-image:generateContent?key=${KEY}`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ contents: [{ role: "user", parts: [{ text: prompt }] }], generationConfig: { responseModalities: ["IMAGE", "TEXT"], imageConfig: { aspectRatio: "16:9", imageSize: "2K" } } }),
    });
    if (r.ok) { const d = await r.json(); const part = (d.candidates?.[0]?.content?.parts || []).find(p => p.inlineData); if (part) { writeFileSync(out, Buffer.from(part.inlineData.data, "base64")); return true; } }
    else if (r.status === 429 || r.status >= 500) { await new Promise(s => setTimeout(s, a * 15000)); continue; }
    else { console.error(`  ${r.status}: ${(await r.text()).slice(0, 160)}`); return false; }
  }
  return false;
}

let made = 0;
for (const p of todo) {
  const subj = p.hero || HERO[p.slug] || `${p.title}. ${p.dek || ""}`;
  process.stdout.write(`${p.slug} … `);
  const png = join(HERE, "img", `${p.slug}.png`);
  if (await gen(`${subj}. ${CANON}`, png)) {
    execSync(`sips -s format jpeg "${png}" --out "${join(HERE, "img", `${p.slug}.jpg`)}" >/dev/null 2>&1 && rm -f "${png}"`);
    console.log("ok"); made++;
  } else console.log("FAILED");
}
console.log(`blog heroes — ${made} generated`);
