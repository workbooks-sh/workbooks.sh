#!/usr/bin/env node
// Narration generator — ElevenLabs v3, expressive, with character timestamps.
// Reads scripts/*.json, writes raw/<slug>--<id>.mp3 + align/<slug>--<id>.json.
// Idempotent: skips tracks whose mp3 already exists (delete to regenerate).
// Usage: XI_API_KEY=… node generate.mjs [slug …]

import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const KEY = process.env.XI_API_KEY;
if (!KEY) { console.error("XI_API_KEY not set"); process.exit(1); }

const VOICE = "q0IMILNRPxOgtBTS4taI";          // library narrator — v3 expressive test
const MODEL = "eleven_v3";
const SETTINGS = { stability: 0.0 };            // creative — maximum tag response
const FORMAT = "mp3_44100_64";

mkdirSync(join(HERE, "raw"), { recursive: true });
mkdirSync(join(HERE, "align"), { recursive: true });

const only = process.argv.slice(2);
const scripts = readdirSync(join(HERE, "scripts"))
  .filter((f) => f.endsWith(".json"))
  .map((f) => JSON.parse(readFileSync(join(HERE, "scripts", f), "utf8")))
  .filter((s) => !only.length || only.includes(s.slug));

async function tts(text) {
  for (let attempt = 1; attempt <= 4; attempt++) {
    const r = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${VOICE}/with-timestamps?output_format=${FORMAT}`,
      {
        method: "POST",
        headers: { "xi-api-key": KEY, "content-type": "application/json" },
        body: JSON.stringify({ model_id: MODEL, text, voice_settings: SETTINGS }),
      }
    );
    if (r.ok) return r.json();
    const body = await r.text();
    if (r.status === 429 || r.status >= 500) {
      const wait = attempt * 15000;
      console.error(`  ${r.status} — retrying in ${wait / 1000}s`);
      await new Promise((res) => setTimeout(res, wait));
      continue;
    }
    throw new Error(`${r.status}: ${body.slice(0, 300)}`);
  }
  throw new Error("gave up after retries");
}

let made = 0, skipped = 0;
for (const page of scripts) {
  for (const t of page.tracks) {
    const stem = `${page.slug}--${t.id}`;
    const mp3 = join(HERE, "raw", `${stem}.mp3`);
    if (existsSync(mp3)) { skipped++; continue; }
    process.stdout.write(`${stem} … `);
    const d = await tts(t.text);
    writeFileSync(mp3, Buffer.from(d.audio_base64, "base64"));
    // keep only what pacing needs: char + end-time arrays
    const a = d.alignment || {};
    writeFileSync(
      join(HERE, "align", `${stem}.json`),
      JSON.stringify({
        characters: a.characters,
        ends: a.character_end_times_seconds,
      })
    );
    const dur = (a.character_end_times_seconds || [0]).at(-1);
    console.log(`${dur?.toFixed(1)}s`);
    made++;
    await new Promise((res) => setTimeout(res, 600)); // be polite
  }
}
console.log(`done — ${made} generated, ${skipped} already present`);
