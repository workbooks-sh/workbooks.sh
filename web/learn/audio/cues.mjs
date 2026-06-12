#!/usr/bin/env node
// Cue generator — ElevenLabs Music with composition plans (timed sections).
// Instead of a droning bed, each lesson gets three DYNAMIC cues:
//   intro — statement → settle → decay to silence (voice enters over it)
//   turn  — riser → warm phrase → tail (placed at a few chapter moments)
//   outro — gentle build → resolving theme → soft ending
// Idempotent. Usage: XI_API_KEY=… node cues.mjs [slug …]

import { writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const KEY = process.env.XI_API_KEY;
if (!KEY) { console.error("XI_API_KEY not set"); process.exit(1); }
mkdirSync(join(HERE, "cues"), { recursive: true });

const GLOBAL = ["1970s library music", "warm electric piano", "melodic", "optimistic", "instrumental", "gentle rhythm", "podcast theme"];
const NEG = ["vocals", "edm", "harsh", "distortion", "ambient drone", "eerie", "suspense", "dissonant", "cinematic pads"];

const TEMPER = {
  workbook: "bright and curious, soft major key",
  nexus: "steady and deep, dependable low warmth",
  toolkit: "playful workshop tinkering, light plucky analog",
  org: "spare and focused, elegant minimalism",
  agents: "patient gentle pulse, quietly determined",
  autopoet: "organic and tender, growing warmth",
  wbx: "precise and crisp, quietly confident",
  bundles: "tidy packing-room temperament, light and satisfying, things clicking into place",
  nesting: "branching garden temperament, gentle recursive motifs, patient growth",
};

// section plans — durations are honored by the API, so placement math is exact.
// The intro is built PER LESSON, sized to its intro narration (read from the
// alignment): theme plays under the whole opening section, comes back in to
// finish it off in the first pause, then ends — dry reading follows.
function introPlan(voiceDur) {
  // a real TUNE: title theme, then quiet musical motion under the voice
  const under = Math.max(3000, Math.round((voiceDur - 3.2) * 1000));
  return [
    ["opening statement", ["bright memorable title melody", "warm electric piano lead", "soft bass", "welcoming"], 6000],
    ["under the voice", ["quiet melodic undercurrent", "soft and supportive", "subtle movement", "low in the mix"], under],
    ["finishing phrase", ["title melody returns brightly", "playful finish", "satisfying button ending"], 5000],
    ["ending", ["fading out completely to silence"], 3000],
  ];
}
const CUES = {
  turn1: [
    ["riser", ["melodic build", "rising electric piano figure"], 3000],
    ["phrase", ["catchy warm electric piano motif", "playful", "light brushed rhythm"], 4200],
    ["tail", ["resolving gently", "fading to silence"], 3000],
  ],
  turn2: [
    ["riser", ["plucked strings building", "bright anticipation"], 3000],
    ["phrase", ["plucked strings and soft flute melody", "cheerful", "bouncy"], 4200],
    ["tail", ["settling down", "fading to silence"], 3000],
  ],
  turn3: [
    ["riser", ["full warm build", "the main theme returning"], 3000],
    ["phrase", ["main theme reprise", "bright and full", "feel-good"], 4200],
    ["tail", ["winding down", "fading to silence"], 3000],
  ],
  outro: [
    ["build", ["melodic build", "gathering brightness", "hopeful"], 5000],
    ["resolve", ["main theme final statement", "full and warm", "satisfying conclusion"], 6000],
    ["ending", ["soft ending", "fading out completely"], 4000],
  ],
};

import { readFileSync } from "node:fs";
function introVoiceDur(slug) {
  try {
    return JSON.parse(readFileSync(join(HERE, "align", `${slug}--intro.json`), "utf8")).ends.at(-1);
  } catch { return 18; }
}

async function gen(slug, kind, out) {
  const sections = kind === "intro" ? introPlan(introVoiceDur(slug)) : CUES[kind];
  const plan = {
    positive_global_styles: GLOBAL.concat([TEMPER[slug] || ""]),
    negative_global_styles: NEG,
    sections: sections.map(([name, styles, ms]) => ({
      section_name: name,
      positive_local_styles: styles,
      negative_local_styles: [],
      duration_ms: ms,
      lines: [],
    })),
  };
  for (let attempt = 1; attempt <= 3; attempt++) {
    const r = await fetch("https://api.elevenlabs.io/v1/music?output_format=mp3_44100_128", {
      method: "POST",
      headers: { "xi-api-key": KEY, "content-type": "application/json" },
      body: JSON.stringify({ composition_plan: plan }),
    });
    if (r.ok) { writeFileSync(out, Buffer.from(await r.arrayBuffer())); return; }
    const t = await r.text();
    if (r.status === 429 || r.status >= 500) { await new Promise((s) => setTimeout(s, attempt * 20000)); continue; }
    throw new Error(`${r.status}: ${t.slice(0, 200)}`);
  }
  throw new Error(`gave up: ${out}`);
}

const slugs = process.argv.slice(2).length ? process.argv.slice(2) : Object.keys(TEMPER);
for (const slug of slugs) {
  for (const kind of ["intro", "turn1", "turn2", "turn3", "outro"]) {
    const out = join(HERE, "cues", `${slug}-${kind}.mp3`);
    if (existsSync(out)) continue;
    process.stdout.write(`cues/${slug}-${kind} … `);
    await gen(slug, kind, out);
    console.log("ok");
  }
}
console.log("cues done");
