#!/usr/bin/env node
// run — the IN-NEXUS WORKBOOK FILMING eval, end to end.
//
// Demonstrates the full "an agent films its own workbook edits" loop using ONLY
// the in-nexus surfaces (no host browser, no Playwright, no real-UI pixels):
//
//   1. BUILD TIMELINE  — synthesize the edit-state timeline a nexus agent emits
//      while authoring a kanban workbook (empty -> title -> sections -> content).
//      Each edit captures the workbook HTML snapshot + a label (build-timeline.mjs).
//      This is exactly what a real agent already has: each `_steps.jsonl` entry +
//      the workbook HTML it just wrote.
//   2. NARRATE         — TTS each step's narration line (ElevenLabs, brokered
//      host call — narration is the ONE host-side step) and pace them across the
//      film's duration into a single track (voiceover.mjs assembly).
//   3. FILM (in-nexus) — `wavelet film timeline.json -o demo.mp4 --audio track` :
//      renders each snapshot as a full-bleed scene with its caption, crossfades
//      between edits, encodes H.264 + muxes the AAC narration — ALL in the wasm
//      sandbox (Blitz render + in-guest ffmpeg). No host ffmpeg touches the video.
//   4. VERIFY          — the recording-toolkit VERIFY cascade (lib/verify-only.mjs)
//      samples the mp4 to frames and asks the vision models: did the walkthrough
//      actually demonstrate the four edits? Gates the upload.
//   5. UPLOAD          — wrangler r2 object put workbooks-media/demos/... --remote.
//
// Env: OPENROUTER_API_KEY (verify), XI_API_KEY (narration), CLOUDFLARE_ACCOUNT_ID
//      + wrangler auth (upload). Missing keys degrade gracefully (skip+flag).
//
// Flags:
//   --out DIR        work dir (default ./out beside this file)
//   --fps N          film fps (default 24)
//   --crossfade S    crossfade seconds between edits (default 0.4)
//   --no-audio       skip narration (silent film)
//   --no-upload      build+verify only, don't push to R2
//   --r2-key KEY     R2 object key (default demos/workbook-demo.mp4)
//
// Prints a JSON manifest on stdout; exit 0 = built+verified (uploaded if asked).

import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";

const exec = promisify(execFile);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const RECORD_ROOT = path.resolve(HERE, "../.."); // tools/record
const REPO_ROOT = path.resolve(RECORD_ROOT, "../.."); // repo root
const RUNTIME = path.join(REPO_ROOT, "runtime");

function parse(argv) {
  const a = { fps: 24, crossfade: 0.4, audio: true, upload: true, r2Key: "demos/workbook-demo.mp4" };
  for (let i = 0; i < argv.length; i++) {
    const x = argv[i];
    if (x === "--out") a.out = argv[++i];
    else if (x === "--fps") a.fps = +argv[++i];
    else if (x === "--crossfade") a.crossfade = +argv[++i];
    else if (x === "--no-audio") a.audio = false;
    else if (x === "--no-upload") a.upload = false;
    else if (x === "--r2-key") a.r2Key = argv[++i];
  }
  return a;
}

async function run(cmd, args, opts = {}) {
  process.stderr.write(`$ ${cmd} ${args.join(" ")}\n`);
  return exec(cmd, args, { maxBuffer: 64 * 1024 * 1024, ...opts });
}

// ── narration: TTS each line + pace into ONE track sized to the film duration ───
// Mirrors voiceover.mjs's assembly but is duration-driven (we know the film length
// from the timeline before the mp4 exists). Produces a single .m4a the in-guest
// film --audio mux trims to the (slightly longer) video.
const XI_KEY = process.env.XI_API_KEY;
const XI_VOICE = process.env.XI_VOICE || "q0IMILNRPxOgtBTS4taI";
const XI_MODEL = process.env.XI_MODEL || "eleven_v3";

async function tts(text, file) {
  for (let attempt = 1; attempt <= 4; attempt++) {
    const r = await fetch(
      `https://api.elevenlabs.io/v1/text-to-speech/${XI_VOICE}?output_format=mp3_44100_128`,
      {
        method: "POST",
        headers: { "xi-api-key": XI_KEY, "content-type": "application/json" },
        body: JSON.stringify({ model_id: XI_MODEL, text, voice_settings: { stability: 0.35, similarity_boost: 0.75 } }),
      }
    );
    if (r.ok) {
      await fs.writeFile(file, Buffer.from(await r.arrayBuffer()));
      return file;
    }
    const body = await r.text();
    if (r.status === 429 || r.status >= 500) {
      await new Promise((res) => setTimeout(res, attempt * 6000));
      continue;
    }
    throw new Error(`ElevenLabs ${r.status}: ${body.slice(0, 200)}`);
  }
  throw new Error("ElevenLabs: gave up after retries");
}

async function probeDuration(file) {
  const { stdout } = await exec("ffprobe", [
    "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", file,
  ]);
  return parseFloat(stdout.trim()) || 0;
}

// Build a single narration track ~`targetDur`s long: each line starts at the
// cumulative start of its edit-state hold (so the voice tracks the action it
// describes), trailing silence pads to length. Uses host ffmpeg ONLY to assemble
// the narration audio asset — the VIDEO render/encode/mux stays fully in-nexus.
async function buildNarration(lines, starts, targetDur, workDir) {
  const clips = [];
  for (let i = 0; i < lines.length; i++) {
    const f = path.join(workDir, `line-${i}.mp3`);
    await tts(lines[i], f);
    clips.push(f);
  }
  const inputs = [];
  const filters = [];
  clips.forEach((c, i) => {
    inputs.push("-i", c);
    const delayMs = Math.max(0, Math.round(starts[i] * 1000));
    filters.push(`[${i}:a]adelay=${delayMs}|${delayMs}[a${i}]`);
  });
  const mixIn = clips.map((_, i) => `[a${i}]`).join("");
  // MP3 — the in-guest `wavelet film --audio` decoder lane handles mp3/aac/wav;
  // an m4a (ISO-BMFF) container is NOT decodable in-guest and fails the encode.
  const out = path.join(workDir, "narration.mp3");
  const fc =
    filters.join(";") +
    `;${mixIn}amix=inputs=${clips.length}:normalize=0[mix];[mix]apad,atrim=0:${targetDur.toFixed(3)}[out]`;
  await exec("ffmpeg", ["-y", ...inputs, "-filter_complex", fc, "-map", "[out]", "-c:a", "libmp3lame", "-b:a", "160k", out]);
  return out;
}

// Compute the film duration + each step's caption-onset start (seconds) from the
// timeline, matching render_film's frame math: hold_i frames per step + crossfade
// frames BETWEEN consecutive steps. A step's hold begins after all prior holds +
// crossfades, so narration line i should start at the BEGINNING of step i's hold.
function filmTiming(steps, fps, crossfade) {
  const holdF = (h) => Math.round(fps * (h && h > 0 ? h : 2.0));
  const crossF = Math.round(fps * crossfade);
  let frames = 0;
  const starts = [];
  steps.forEach((s, i) => {
    if (i > 0) frames += crossF; // crossfade precedes this step's hold
    starts.push(frames / fps);
    frames += holdF(s.hold_secs);
  });
  return { durSecs: frames / fps, starts };
}

async function main() {
  const a = parse(process.argv.slice(2));
  const outDir = path.resolve(a.out || path.join(HERE, "out"));
  await fs.mkdir(outDir, { recursive: true });

  const manifest = { eval: "in-nexus-workbook", fps: a.fps, crossfade: a.crossfade, steps: [], stages: {} };

  // 1) BUILD TIMELINE (snapshots live in the eval dir; the film lane stages that dir)
  process.stderr.write("== 1. build edit-state timeline ==\n");
  await run("node", [path.join(HERE, "build-timeline.mjs"), "--out", HERE]);
  const timelinePath = path.join(HERE, "timeline.json");
  const steps = JSON.parse(await fs.readFile(timelinePath, "utf8"));
  const narration = JSON.parse(await fs.readFile(path.join(HERE, "narration.json"), "utf8")).lines;
  const expected = await fs.readFile(path.join(HERE, "expected.txt"), "utf8");
  manifest.steps = steps.map((s) => s.label);
  manifest.stages.timeline = { ok: true, count: steps.length, file: timelinePath };

  // 2) NARRATE (host-brokered TTS -> one paced track sized to the film)
  const { durSecs, starts } = filmTiming(steps, a.fps, a.crossfade);
  manifest.duration_target = Number(durSecs.toFixed(2));
  let audioPath = null;
  const voWork = await fs.mkdtemp(path.join(os.tmpdir(), "wb-nexus-vo-"));
  if (a.audio) {
    if (!XI_KEY) {
      process.stderr.write("== 2. narrate: SKIP (no XI_API_KEY) — silent film ==\n");
      manifest.stages.narration = { ok: false, skipped: true, reason: "no XI_API_KEY" };
    } else {
      process.stderr.write(`== 2. narrate ${narration.length} lines (target ${durSecs.toFixed(1)}s) ==\n`);
      try {
        audioPath = await buildNarration(narration, starts, durSecs, voWork);
        manifest.stages.narration = { ok: true, lines: narration.length, track: audioPath, by: `elevenlabs:${XI_MODEL}` };
      } catch (e) {
        process.stderr.write(`narration failed: ${e.message} — falling back to silent film\n`);
        manifest.stages.narration = { ok: false, error: String(e.message) };
        audioPath = null;
      }
    }
  } else {
    manifest.stages.narration = { ok: false, skipped: true, reason: "--no-audio" };
  }

  // 3) FILM — wavelet film, fully in-nexus (render + encode + mux in the sandbox)
  process.stderr.write("== 3. wavelet film (in-nexus render + encode + narration mux) ==\n");
  const videoPath = path.join(outDir, "workbook-demo.mp4");
  await fs.rm(videoPath, { force: true });
  const filmArgvElixir = JSON.stringify([
    "film", timelinePath, "-o", videoPath,
    "--w", "1280", "--h", "720", "--fps", String(a.fps), "--crossfade", String(a.crossfade),
    ...(audioPath ? ["--audio", audioPath] : []),
  ]);
  const elixir = `
    argv = ${filmArgvElixir} |> Enum.map(&to_string/1)
    case Workbooks.Wavelet.command(argv) do
      {:ok, out} -> IO.puts("FILM_OK " <> out)
      other -> IO.puts("FILM_ERR " <> inspect(other)); System.halt(1)
    end
  `;
  const { stdout: filmOut } = await run("mix", ["run", "--no-start", "-e", elixir], { cwd: RUNTIME });
  if (!/FILM_OK/.test(filmOut)) throw new Error(`film did not report OK:\n${filmOut}`);
  const probe = await exec("ffprobe", [
    "-v", "error", "-show_entries", "format=duration:stream=codec_type,codec_name",
    "-of", "json", videoPath,
  ]).then((r) => JSON.parse(r.stdout));
  const vstreams = (probe.streams || []).map((s) => `${s.codec_type}:${s.codec_name}`);
  manifest.stages.film = {
    ok: true, video: videoPath,
    duration: Number(parseFloat(probe.format.duration).toFixed(2)),
    streams: vstreams, narrated: !!audioPath, engine: "in-guest (wasm: Blitz render + ffmpeg encode/mux)",
  };
  process.stderr.write(`film -> ${videoPath} (${manifest.stages.film.duration}s, ${vstreams.join(", ")})\n`);

  // 4) VERIFY — the recording-toolkit cascade gates the upload (require pass)
  process.stderr.write("== 4. vision-verify (recording-toolkit cascade) ==\n");
  const expectedFile = path.join(outDir, "expected.txt");
  await fs.writeFile(expectedFile, expected);
  // last edit-state HTML is the natural DOM signal for the verifier
  const lastHtml = await fs.readFile(path.join(HERE, steps[steps.length - 1].snapshot_file), "utf8");
  const signalsFile = path.join(outDir, "signals.json");
  await fs.writeFile(signalsFile, JSON.stringify({ console: [], html: lastHtml }));
  let verifyJson, verifyCode;
  try {
    const { stdout } = await run("node", [
      path.join(RECORD_ROOT, "lib", "verify-only.mjs"),
      "--video", videoPath, "--expected-file", expectedFile, "--signals-file", signalsFile, "--frames", "8",
    ]);
    verifyJson = JSON.parse(stdout);
    verifyCode = 0;
  } catch (e) {
    // verify-only exits 1 on a real FAIL; capture the verdict it printed
    try { verifyJson = JSON.parse(e.stdout || "{}"); } catch { verifyJson = { verdict: "error", stderr: String(e.stderr || e.message) }; }
    verifyCode = e.code ?? 1;
  }
  manifest.stages.verify = verifyJson;
  const verified = verifyJson.verdict === "pass" || verifyJson.skipped;
  process.stderr.write(`verify -> ${verifyJson.verdict}${verifyJson.skipped ? " (skipped, no key)" : ""}\n`);
  if (!verified) {
    manifest.ok = false;
    console.log(JSON.stringify(manifest, null, 2));
    await fs.rm(voWork, { recursive: true, force: true }).catch(() => {});
    process.exit(1); // gate: a real FAIL blocks the upload
  }

  // 5) UPLOAD to R2 via wrangler (the share step)
  if (a.upload) {
    process.stderr.write("== 5. upload to R2 ==\n");
    const objectPath = `workbooks-media/${a.r2Key}`;
    try {
      const env = { ...process.env };
      const { stdout } = await run("wrangler", ["r2", "object", "put", objectPath, "--file", videoPath, "--remote"], { env });
      manifest.stages.upload = { ok: true, object: objectPath, out: stdout.trim().slice(0, 400) };
      process.stderr.write(`uploaded -> ${objectPath}\n`);
    } catch (e) {
      manifest.stages.upload = { ok: false, object: objectPath, error: String(e.stderr || e.message).slice(0, 400) };
      process.stderr.write(`upload failed: ${manifest.stages.upload.error}\n`);
    }
  } else {
    manifest.stages.upload = { ok: false, skipped: true, reason: "--no-upload" };
  }

  await fs.rm(voWork, { recursive: true, force: true }).catch(() => {});
  manifest.ok = true;
  await fs.writeFile(path.join(outDir, "manifest.json"), JSON.stringify(manifest, null, 2));
  console.log(JSON.stringify(manifest, null, 2));
}

main().catch((e) => {
  console.error("eval fatal:", e);
  process.exit(1);
});
