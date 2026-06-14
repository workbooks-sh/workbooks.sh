#!/usr/bin/env node
// voiceover — add a narrated audio track to a recorded demo MP4.
//
// The recording harness captures silent video. This stage:
//   1. reads a narration script (recipe.voiceover.lines | --script FILE | --lines),
//   2. generates one TTS clip per line via ElevenLabs (v3 expressive — same call
//      pattern as web/learn/audio/generate.mjs, same XI_API_KEY),
//   3. paces the clips evenly across the video's real duration (silence-padded
//      between lines so narration tracks the on-screen action), and
//   4. muxes the assembled voiceover into a fresh MP4 (video copied, audio AAC).
//
// Usage:
//   node lib/voiceover.mjs --video out/take.mp4 --out out/take.voiced.mp4 \
//        [--script narration.json] [--line "..." --line "..."]
//
// Script JSON: { "lines": ["...", "..."] }  (or a bare ["...","..."] array).
// Env: XI_API_KEY (required). XI_VOICE / XI_MODEL override the default voice/model.
//
// Prints a JSON manifest on stdout: { voiced, video, duration, lines, by }.
// Exit 0 = a voiced MP4 was produced; 1 = could not (no key / no lines / ffmpeg).

import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const exec = promisify(execFile);

const KEY = process.env.XI_API_KEY;
const VOICE = process.env.XI_VOICE || "q0IMILNRPxOgtBTS4taI"; // library narrator (v3)
const MODEL = process.env.XI_MODEL || "eleven_v3";
const FORMAT = "mp3_44100_128";

function parse(argv) {
  const a = { lines: [] };
  for (let i = 0; i < argv.length; i++) {
    const x = argv[i];
    if (x === "--video") a.video = argv[++i];
    else if (x === "--out") a.out = argv[++i];
    else if (x === "--script") a.script = argv[++i];
    else if (x === "--line") a.lines.push(argv[++i]);
  }
  return a;
}

async function loadLines(a) {
  if (a.lines.length) return a.lines;
  if (a.script) {
    const raw = JSON.parse(await fs.readFile(a.script, "utf8"));
    return Array.isArray(raw) ? raw : raw.lines || [];
  }
  return [];
}

// Read lines straight from a recipe's voiceover block (used by the pipeline).
export async function linesFromRecipe(recipePath) {
  try {
    const r = JSON.parse(await fs.readFile(recipePath, "utf8"));
    const vo = r.voiceover;
    if (!vo) return [];
    return Array.isArray(vo) ? vo : vo.lines || [];
  } catch {
    return [];
  }
}

async function tts(text, file) {
  for (let attempt = 1; attempt <= 4; attempt++) {
    const r = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${VOICE}?output_format=${FORMAT}`,
      {
        method: "POST",
        headers: { "xi-api-key": KEY, "content-type": "application/json" },
        body: JSON.stringify({ model_id: MODEL, text, voice_settings: { stability: 0.3, similarity_boost: 0.75 } }),
      }
    );
    if (r.ok) {
      const buf = Buffer.from(await r.arrayBuffer());
      await fs.writeFile(file, buf);
      return file;
    }
    const body = await r.text();
    if (r.status === 429 || r.status >= 500) {
      await new Promise((res) => setTimeout(res, attempt * 8000));
      continue;
    }
    throw new Error(`ElevenLabs ${r.status}: ${body.slice(0, 200)}`);
  }
  throw new Error("ElevenLabs: gave up after retries");
}

async function probeDuration(file) {
  const { stdout } = await exec("ffprobe", [
    "-v", "error", "-show_entries", "format=duration",
    "-of", "default=noprint_wrappers=1:nokey=1", file,
  ]);
  return parseFloat(stdout.trim()) || 0;
}

// Build a single voiceover track the length of the video: each line starts at an
// evenly-distributed slot so narration tracks the on-screen action; trailing
// silence pads to the full video duration. Returns the assembled mp3 path.
async function assembleTrack(clips, videoDur, workDir) {
  const clipDurs = [];
  for (const c of clips) clipDurs.push(await probeDuration(c));
  const totalSpeech = clipDurs.reduce((s, d) => s + d, 0);
  // Distribute the slack (video time not occupied by speech) as gaps: a small
  // lead-in, then even gaps between lines. Never negative.
  const slack = Math.max(0, videoDur - totalSpeech);
  const lead = Math.min(0.8, slack * 0.25);
  const gaps = clips.length > 1 ? (slack - lead) / (clips.length - 1) : 0;

  // adelay each clip to its start offset, then amix; apad to video length.
  let t = lead;
  const inputs = [];
  const filters = [];
  clips.forEach((c, i) => {
    inputs.push("-i", c);
    const delayMs = Math.round(t * 1000);
    filters.push(`[${i}:a]adelay=${delayMs}|${delayMs}[a${i}]`);
    t += clipDurs[i] + gaps;
  });
  const mixIn = clips.map((_, i) => `[a${i}]`).join("");
  const out = path.join(workDir, "voiceover.m4a");
  const filterComplex =
    filters.join(";") +
    `;${mixIn}amix=inputs=${clips.length}:normalize=0[mix];` +
    `[mix]apad,atrim=0:${videoDur.toFixed(3)}[out]`;
  await exec("ffmpeg", [
    "-y", ...inputs,
    "-filter_complex", filterComplex,
    "-map", "[out]", "-c:a", "aac", "-b:a", "160k", out,
  ]);
  return out;
}

// Public: voice a video. Returns { voiced, duration, lines } or throws.
export async function voiceVideo({ video, out, lines }) {
  if (!KEY) throw new Error("XI_API_KEY not set — cannot synthesize voiceover");
  if (!lines || !lines.length) throw new Error("no narration lines provided");
  const videoDur = await probeDuration(video);
  if (!videoDur) throw new Error(`could not read video duration: ${video}`);

  const workDir = await fs.mkdtemp(path.join(os.tmpdir(), "wb-vo-"));
  try {
    const clips = [];
    for (let i = 0; i < lines.length; i++) {
      const f = path.join(workDir, `line-${i}.mp3`);
      await tts(lines[i], f);
      clips.push(f);
    }
    const track = await assembleTrack(clips, videoDur, workDir);
    const voiced = out || video.replace(/\.mp4$/, ".voiced.mp4");
    await exec("ffmpeg", [
      "-y", "-i", video, "-i", track,
      "-c:v", "copy", "-c:a", "aac", "-map", "0:v:0", "-map", "1:a:0",
      "-shortest", voiced,
    ]);
    return { voiced, video, duration: videoDur, lines: lines.length, by: `elevenlabs:${MODEL}` };
  } finally {
    await fs.rm(workDir, { recursive: true, force: true }).catch(() => {});
  }
}

async function main() {
  const a = parse(process.argv.slice(2));
  if (!a.video) {
    console.error("usage: voiceover.mjs --video FILE [--out FILE] [--script JSON | --line '...' ...]");
    process.exit(2);
  }
  const lines = await loadLines(a);
  try {
    const m = await voiceVideo({ video: a.video, out: a.out, lines });
    console.log(JSON.stringify(m, null, 2));
    process.exit(0);
  } catch (e) {
    console.log(JSON.stringify({ voiced: null, error: String(e.message) }, null, 2));
    process.exit(1);
  }
}

// run as CLI only
if (import.meta.url === `file://${process.argv[1]}`) main();
