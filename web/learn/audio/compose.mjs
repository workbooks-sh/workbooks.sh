#!/usr/bin/env node
// The episode composer — one fully-produced episode per lesson.
//
// Scoring model: DYNAMIC CUES, not a constant bed. The voice is dry most of
// the time; music appears as composed moments with their own builds and
// decays (generated with timed composition plans — cues.mjs):
//
//   ┌ intro cue at 0:00 — a statement that settles and decays; the narrator
//   │ enters over it at ~2.8s and the music gets out of the way on its own
//   ├ dry narration; ordinary section boundaries are just a breath
//   ├ at a few chosen TURNS per lesson: the turn cue's riser starts under
//   │ the closing words of the previous section, the phrase peaks in a
//   │ widened gap, and its tail ducks under the next section's open
//   └ outro cue rises under the final lines and resolves after the voice ends
//
// Light sidechain keeps cue tails polite under speech without killing the
// dynamics. Output: episodes/<slug>.mp3 + manifest.json (chapters for the
// player's seek list).
//
// Usage: node compose.mjs [slug …]      (ffmpeg + ffprobe required)

import { readFileSync, writeFileSync, readdirSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const HERE = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(HERE, "episodes"), { recursive: true });

const only = process.argv.slice(2);
const scripts = readdirSync(join(HERE, "scripts"))
  .filter((f) => f.endsWith(".json"))
  .map((f) => JSON.parse(readFileSync(join(HERE, "scripts", f), "utf8")))
  .filter((s) => !only.length || only.includes(s.slug));

const ORDER = ["workbook", "nexus", "toolkit", "org", "agents", "autopoet", "wbx", "workflows", "vfs"];
scripts.sort((a, b) => ORDER.indexOf(a.slug) - ORDER.indexOf(b.slug));

// ── the shape ────────────────────────────────────────────────────────────────
const OPEN = 2.8;          // intro cue alone before the narrator enters
const GAP = 0.9;           // breath between ordinary sections
const INTRO_GAP = 6.2;     // after the opening section: the theme returns and buttons it off
const TURN_GAP = 3.4;      // widened gap where a turn cue's phrase lands
const RISER_LEAD = 1.8;    // turn riser starts this far before the prior section ends
const OUTRO_LEAD = 2.5;    // outro build starts under the final lines
const MUSIC_DB = -7;       // cue level — present, musical
const DUCK = "threshold=0.02:ratio=3.5:attack=150:release=1100"; // polite, not flattening

// musical turns per lesson — a few real moments, NOT every section
const TURNS = {
  workbook: ["definition", "org-layer", "faq"],
  nexus: ["definition", "why-not", "faq"],
  toolkit: ["definition", "wasm", "faq"],
  org: ["definition", "why-not", "faq"],
  agents: ["definition", "boundaries", "faq"],
  autopoet: ["definition", "does", "faq"],
  wbx: ["definition", "first", "faq"],
  workflows: ["definition", "compile", "faq"],
  vfs: ["definition", "workspace", "faq"],
};

const fdur = (f) =>
  parseFloat(execFileSync("ffprobe", ["-v", "quiet", "-show_entries", "format=duration", "-of", "csv=p=0", f]).toString());

const manifest = { episodes: [] };
let made = 0;

for (const page of scripts) {
  const out = join(HERE, "episodes", `${page.slug}.mp3`);
  const turns = new Set(TURNS[page.slug] || []);
  const cue = (k) => join(HERE, "cues", `${page.slug}-${k}.mp3`);
  if (!["intro", "turn1", "turn2", "turn3", "outro"].every((k) => existsSync(cue(k)))) {
    console.error(`${page.slug}: cues missing — run cues.mjs ${page.slug}`);
    continue;
  }

  // ── timeline ──
  let t = OPEN;
  const segs = [], chapters = [], cues = [{ file: cue("intro"), at: 0 }];
  let missing = false;
  for (const trk of page.tracks) {
    const raw = join(HERE, "raw", `${page.slug}--${trk.id}.mp3`);
    if (!existsSync(raw)) { missing = true; break; }
    let d;
    try {
      d = JSON.parse(readFileSync(join(HERE, "align", `${page.slug}--${trk.id}.json`), "utf8")).ends.at(-1);
    } catch { d = fdur(raw); }
    if (segs.length) {
      if (segs.length === 1) {
        t += INTRO_GAP;      // the intro cue's finishing phrase lands here
      } else if (turns.has(trk.id)) {
        const nth = cues.filter((c) => c.file.includes("-turn")).length + 1;
        cues.push({ file: cue("turn" + Math.min(nth, 3)), at: Math.max(0, t - RISER_LEAD) });
        t += TURN_GAP;
      } else {
        t += GAP;
      }
    }
    segs.push({ raw, at: t });
    chapters.push({ id: trk.id, title: trk.title, t: Math.max(0, Math.round(t - 1)) });
    t += d;
  }
  if (missing) { console.error(`${page.slug}: narration incomplete — skipped`); continue; }

  const outroAt = Math.max(0, t - OUTRO_LEAD);
  cues.push({ file: cue("outro"), at: outroAt });
  const total = Math.max(t, outroAt + fdur(cue("outro"))).toFixed(2) * 1 + 0.5;

  if (!existsSync(out)) {
    const inputs = [];
    let graph = "";
    const vox = [], mus = [];
    segs.forEach((s) => {
      const i = inputs.length / 2;
      inputs.push("-i", s.raw);
      const ms = Math.round(s.at * 1000);
      graph += `[${i}:a]adelay=${ms}|${ms}[v${i}];`;
      vox.push(`[v${i}]`);
    });
    cues.forEach((c) => {
      const i = inputs.length / 2;
      inputs.push("-i", c.file);
      const ms = Math.round(c.at * 1000);
      graph += `[${i}:a]adelay=${ms}|${ms},volume=${MUSIC_DB}dB[m${i}];`;
      mus.push(`[m${i}]`);
    });
    graph +=
      `${vox.join("")}amix=inputs=${vox.length}:duration=longest:normalize=0[voice];` +
      `${mus.join("")}amix=inputs=${mus.length}:duration=longest:normalize=0[music];` +
      `[voice]asplit[va][vb];` +
      `[music][va]sidechaincompress=${DUCK}[muz];` +
      `[muz][vb]amix=inputs=2:duration=longest:normalize=0[mix];` +
      `[mix]alimiter=limit=0.93,apad=whole_dur=${total},atrim=0:${total}[out]`;

    execFileSync("ffmpeg", [
      "-v", "error", "-y", ...inputs,
      "-filter_complex", graph, "-map", "[out]",
      "-c:a", "libmp3lame", "-b:a", "96k", "-ar", "44100", "-ac", "2",
      out,
    ]);
    made++;
    console.log(`${page.slug}: ${(total / 60).toFixed(1)} min · ${segs.length} segments · ${cues.length} cues`);
  }

  manifest.episodes.push({
    slug: page.slug,
    title: page.title,
    src: `audio/episodes/${page.slug}.mp3`,
    dur: Math.round(fdur(out)),
    chapters,
  });
}

writeFileSync(join(HERE, "manifest.json"), JSON.stringify(manifest, null, 1));
const mins = manifest.episodes.reduce((n, e) => n + e.dur, 0) / 60;
console.log(`composed ${made} new · ${manifest.episodes.length} episodes · ${mins.toFixed(1)} min total`);
