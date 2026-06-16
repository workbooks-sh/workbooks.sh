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
  work: "precise and crisp, quietly confident",
  bundles: "tidy packing-room temperament, light and satisfying, things clicking into place",
  nesting: "branching garden temperament, gentle recursive motifs, patient growth",

  // workbook subs
  signatures: "sealed-wax certainty, formal but warm, a confident stamp",
  specs: "self-describing clarity, an inner voice naming itself, calm and tidy",
  git: "steady ledger pulse, one true line of history, dependable forward march",
  sharing: "open-handed warmth, a trusted handoff, generous and bright",
  postures: "poised and composed, three calm stances, dignified restraint",
  publishing: "doors-open fanfare, gentle outward reach, welcoming arrival",

  // nexus subs
  "the-dock": "doorway warmth, a membrane gently breathing, measured welcome",
  capabilities: "careful grant-by-grant temperament, measured generosity, quiet trust",
  sandboxes: "soft state-machine motion, contained and unhurried, gentle transitions",
  keepers: "patient caretaker pulse, ticking quietly through empty rooms, faithful",
  planes: "two-lane parallel calm, public bright over private warm, orderly",
  deployments: "lift-off-but-gentle, settling into place, assured arrival",
  telemetry: "single clean signal pulse, one grammar repeating, lucid and steady",
  gitops: "synced heartbeat warmth, commits flowing to light, living changelog",
  "hot-swap": "live replacement grace, a part trading mid-motion, seamless and smooth",
  networking: "brokered-connection calm, granted threads only, trusted and clear",
  channels: "inbox-pairing friendliness, voices arriving in order, hospitable",
  secrets: "discreet keeper temperament, held close until the threshold, quietly safe",
  browsing: "open-window curiosity, reaching outward gently, bright exploration",
  tokens: "once-minted permanence, a stable warm key held forever, reassuring",
  changelogs: "live-narration warmth, people and agents building together, companionable",

  // toolkit subs
  imports: "many-shapes-welcomed temperament, translating with friendly care, adaptive",
  audits: "checklist-and-tidy temperament, sorting into ready piles, satisfying order",
  lanes: "ingenious workshop temperament, clever compilers humming, playful craft",
  promotion: "earned-graduation warmth, session rising to home, proud and gentle",
  trust: "signed-handshake certainty, identity bound warmly, two-layer assurance",
  verification: "quality-gate steadiness, tests passing one by one, calm rigor",
  commands: "small-tool clatter, stdin to stdout briskly, neat plucky utility",

  // org subs
  syntax: "grammar-drill clarity, each construct ringing true, precise and bright",
  tangling: "weaving-loom temperament, threads compiling into shape, intricate calm",
  drawers: "labeled-record tidiness, key meeting value neatly, orderly warmth",
  timestamps: "clockwork-morning temperament, dates ticking into action, punctual cheer",
  "the-kernel": "tiny-core elegance, one pure source many faces, lean and luminous",
  todos: "checkbox-progress lift, states turning to done, quietly accomplished",
  tags: "sorting-by-color brightness, meaning machines can filter, crisp and light",
  claims: "honest-reckoning temperament, talk audited to truth, candid and warm",

  // agents subs
  loops: "model-tools cycle pulse, one readable run breathing, steady and clear",
  authoring: "writing-a-being warmth, plain words becoming an agent, gentle craft",
  "context-repo": "memory-as-files calm, everything diffable in one place, grounded",
  spawning: "comes-alive-and-stays warmth, a run outliving its caller, resilient",
  orchestration: "shared-board cadence, a crew keeping time together, cooperative pulse",
  "human-in-the-loop": "checkpoint-handshake warmth, a person stepping in, trusting pause",
  "runtime-config": "knob-by-knob tidiness, shaping without touching the core, deft",
  dreaming: "drifting daylight reverie, digesting toward bright verdicts, half-awake wonder",
  evals: "fair-judgment composure, briefs in and verdicts out, measured calm",
  "the-ledger": "hash-chained permanence, every step sealed and signed, tamper-proof warmth",
  fleets: "many-workers-one-manifest, staggered boots in concert, organized warmth",
  rehearsals: "dress-rehearsal brightness, real persona scripted through, lively proof",

  // work subs
  modes: "two-audiences-one-binary poise, switching cleanly, adaptable confidence",
  pipelines: "stdin-flowing-through temperament, verbs composing briskly, fluid craft",
  doctor: "self-checkup reassurance, reporting never judging, gentle and steady",
  "deploy-kit": "scaffold-and-converge temperament, one verb set settling in, assured",
  "the-seam": "one-trait-divides-two calm, native and brokered meeting, elegant balance",
  recipes: "fill-five-hooks tinkering, providers slotting in, light modular play",
  distribution: "three-lanes-one-binary brightness, installs flowing out, generous reach",

  // workflows subs
  validations: "proof-not-promise steadiness, claims checked to true, calm rigor",
  schedules: "morning-cron temperament, plans firing on the breath, punctual warmth",
  boards: "one-file-two-way calm, render and write-back simple, lucid order",
  waves: "topological-tide motion, parallel steps cresting together, flowing momentum",
  worlds: "edges-inferred elegance, outputs and inputs matching, architectural calm",
  upgrades: "safe-evolution composure, growing without breaking, careful forward warmth",
  dispatch: "hand-off-and-hear-back warmth, work queued and answered, conversational pulse",

  // vfs subs
  queries: "one-statement-across-many calm, querying the disk cleanly, lucid reach",
  volumes: "three-named-regions tidiness, knowing where a byte lives, grounded order",
  sync: "disk-heartbeat warmth, freeze and resume gently, faithful copy pulse",
  privacy: "one-boundary composure, what-leaves decided calmly, protective warmth",
  "sealed-sections": "ciphertext-to-plaintext grace, the right key opening light, quiet reveal",
  "foreign-tables": "reach-past-the-file curiosity, FROM touching the world, bright connection",
  vectors: "semantic-index shimmer, meaning mapped to numbers, lucid and light",
  backends: "swap-the-storage calm, same code many homes, modular steadiness",
  escrow: "key-release-on-trust warmth, held until the posture clears, careful grace",
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
