#!/usr/bin/env node
// THE driver + proof-loop harness. Claude-Code-runnable.
//
//   node tools/record/record.mjs <recipe.json> [--backend mcp|playwright|auto]
//        [--retries N] [--timeout-ms MS] [--no-verify] [--out DIR]
//
// Flow: load recipe -> pick backend (auto: MCP if the app's socket is live, else
// Playwright) -> drive steps (capturing video on the web backend, frame-grabbing
// stills on both) -> run the VERIFY cascade (Gemini -> MiniMax) -> PASS publishes,
// FAIL re-drives, bounded by wall-clock TIMEOUT_MS (no turn cap, per canon).
//
// Output: a manifest JSON the caller (Claude Code / a workflow) reads to know
// whether the artifact is publishable, plus the video + stills under --out.

import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { validateStep, sleep } from "./lib/intents.mjs";
import { McpBackend } from "./lib/backend-mcp.mjs";
import { verifyRecording } from "./lib/verify.mjs";
import { loadWork, demoToRecipe } from "./lib/dsl.mjs";
import { toSeconds, fmt } from "./lib/timecode.mjs";
// Playwright is imported LAZILY (in makeBackend) so the app/MCP tier — which runs
// in the Linux substrate where Chromium/Playwright may not be installed — loads
// and drives the real Tauri app without the web-walkthrough dependency present.

const HERE = path.dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const a = { backend: "auto", retries: 1, timeoutMs: 600000, verify: true, out: null, emitContext: false };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const x = argv[i];
    if (x === "--backend") a.backend = argv[++i];
    else if (x === "--retries") a.retries = +argv[++i];
    else if (x === "--timeout-ms") a.timeoutMs = +argv[++i];
    else if (x === "--no-verify") a.verify = false;
    else if (x === "--out") a.out = argv[++i];
    // emit <take>.expected.txt + <take>.signals.json so an external verifier
    // (the pipeline orchestrator, gating the REAL capture MP4) can reuse them.
    else if (x === "--emit-context") a.emitContext = true;
    else rest.push(x);
  }
  a.recipe = rest[0];
  return a;
}

async function loadRecipe(p) {
  // .work timeline (frame-accurate, single source of truth) or legacy JSON recipe.
  let recipe;
  if (/\.work$/i.test(p)) {
    const demo = await loadWork(p);
    for (const w of demo.warnings) process.stderr.write(`dsl warn: ${w}\n`);
    recipe = demoToRecipe(demo);
  } else {
    recipe = JSON.parse(await fs.readFile(p, "utf8"));
  }
  if (!recipe.name) throw new Error("recipe needs a name");
  if (!Array.isArray(recipe.steps)) throw new Error("recipe needs steps[]");
  recipe.steps.forEach(validateStep);
  return recipe;
}

async function pickBackend(want, recipe) {
  if (want === "mcp") return "mcp";
  if (want === "playwright") return "playwright";
  // auto: recipe target hints + live socket probe
  if (recipe.target === "app") {
    const p = await McpBackend.probe();
    if (p.ok) return "mcp";
    console.error(`[auto] app recipe but MCP socket unavailable (${p.reason}); cannot fall back to Playwright for the Tauri app.`);
    return "mcp"; // honest: the app can only be driven by MCP
  }
  // web recipe (has a navigate/url)
  return "playwright";
}

async function makeBackend(kind, outDir, recipe) {
  if (kind === "mcp") return await new McpBackend({ outDir }).connect();
  const { PlaywrightBackend } = await import("./lib/backend-playwright.mjs");
  return await new PlaywrightBackend({
    outDir,
    headless: recipe.headless ?? false,
    viewport: recipe.viewport ?? { width: 1440, height: 900 },
  }).connect();
}

// Drive one take. Returns { video, stills, signals, timing }.
//
// When the recipe carries `__cues` (an .org timeline), each intent is PACED to
// START at its declared cue frame relative to capture start (sleep-to-mark). The
// previous intent must finish first; if it overruns its slot we log a drift
// warning and fire the next intent immediately (no crash). The ACTUAL landed
// frame of every cue is recorded for the voiceover to delay against.
async function driveOnce(kind, recipe, outDir, takeName) {
  const backend = await makeBackend(kind, outDir, recipe);
  const stills = [];
  const cues = recipe.__cues || null;
  const fps = recipe.fps || 30;
  const timing = [];
  // The capture began ~1s before the driver per the pipeline lead-in; the driver
  // can only mark its OWN start, so cue frames are relative to the driver's t0.
  const t0 = Date.now();
  const nowFrame = () => Math.round(((Date.now() - t0) / 1000) * fps);
  let maxDrift = 0;
  try {
    for (let i = 0; i < recipe.steps.length; i++) {
      const step = recipe.steps[i];
      const label = step.label || step.intent;
      const cue = cues ? cues[i] : null;

      if (cue) {
        // sleep-to-mark: wait until the wall clock reaches the cue's frame
        const targetMs = toSeconds(cue.frame, fps) * 1000;
        const waitMs = targetMs - (Date.now() - t0);
        if (waitMs > 0) await sleep(waitMs);
        else if (waitMs < -(1000 / fps))
          process.stderr.write(`  drift: cue ${i + 1} (${cue.tcode}) overran by ${Math.round(-waitMs)}ms — previous intent ran long\n`);
      }

      const landedFrame = nowFrame();
      process.stderr.write(`  [${i + 1}/${recipe.steps.length}]${cue ? ` @${cue.tcode}(landed ${fmt(landedFrame, fps)})` : ""} ${label}\n`);
      const r = await backend.perform(step);

      if (cue) {
        const driftFrames = landedFrame - cue.frame;
        if (Math.abs(driftFrames) > Math.abs(maxDrift)) maxDrift = driftFrames;
        timing.push({
          cue: i + 1,
          intent: cue.intent,
          tcode: cue.tcode,
          declaredFrame: cue.frame,
          actualFrame: landedFrame,
          driftFrames,
        });
      }

      if (step.intent === "screenshot" && r?.path) stills.push(r.path);
      if (step.checkpoint) {
        // a checkpoint always grabs a still for the verifier to anchor on
        const s = await backend.screenshot(`${takeName}-chk-${i}`);
        stills.push(s.path);
      }
      // Legacy JSON recipes pace by explicit afterMs dwell. Org timelines pace by
      // the NEXT cue's frame (sleep-to-mark above), so afterMs is ignored there.
      if (!cues && step.afterMs) await sleep(step.afterMs);
    }
    if (cues) {
      await fs.writeFile(path.join(outDir, `${takeName}.timing.json`), JSON.stringify(timing, null, 2));
      process.stderr.write(`  timing: max declared-vs-actual drift = ${maxDrift} frame(s) (fps ${fps})\n`);
    }
    const signals = await backend.collectSignals();
    let video = null;
    if (backend.kind === "playwright") {
      video = await backend.finishVideo(takeName); // closes ctx + flushes
    } else {
      // MCP/app capture: the Linux/native screen recorder (record.sh, Phase 1)
      // owns the MP4. Here we still produce a still-strip the verifier can read.
      // If a sibling MP4 was placed at out/<takeName>.mp4 by the recorder, use it.
      const candidate = path.join(outDir, `${takeName}.mp4`);
      try {
        await fs.access(candidate);
        video = candidate;
      } catch {}
    }
    return { video, stills, signals, timing };
  } finally {
    await backend.close();
  }
}

// Build a single "video" the verifier can sample even when there's no MP4: turn
// the still strip into a short slideshow MP4 via ffmpeg so the cascade has frames.
async function stillsToVideo(stills, outFile) {
  if (!stills.length) return null;
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const exec = promisify(execFile);
  const listFile = outFile + ".txt";
  const body = stills.map((s) => `file '${s}'\nduration 1.5`).join("\n") + `\nfile '${stills.at(-1)}'\n`;
  await fs.writeFile(listFile, body);
  try {
    await exec("ffmpeg", ["-y", "-f", "concat", "-safe", "0", "-i", listFile,
      "-vf", "scale=1280:-2,format=yuv420p", "-r", "2", outFile]);
    return outFile;
  } catch {
    return null;
  } finally {
    await fs.rm(listFile, { force: true }).catch(() => {});
  }
}

async function main() {
  const a = parseArgs(process.argv.slice(2));
  if (!a.recipe) {
    console.error("usage: record.mjs <recipe.json> [--backend mcp|playwright|auto] [--retries N] [--timeout-ms MS] [--no-verify] [--out DIR]");
    process.exit(2);
  }
  const recipe = await loadRecipe(path.resolve(a.recipe));
  const slug = recipe.name.replace(/[^a-z0-9]+/gi, "-").toLowerCase();
  const outDir = a.out || path.join(HERE, "out", slug);
  await fs.mkdir(outDir, { recursive: true });

  const kind = await pickBackend(a.backend, recipe);
  process.stderr.write(`recipe: ${recipe.name}\nbackend: ${kind}\nout: ${outDir}\n`);

  const expected = recipe.steps
    .map((s, i) => `${i + 1}. ${s.label || s.intent}${s.checkpoint ? ` (expect: ${s.checkpoint})` : ""}`)
    .join("\n");

  const deadline = Date.now() + a.timeoutMs;
  let attempt = 0;
  let last = null;

  while (attempt <= a.retries && Date.now() < deadline) {
    attempt++;
    const takeName = `${slug}-take${attempt}`;
    process.stderr.write(`\n=== take ${attempt} ===\n`);
    let drive;
    try {
      drive = await driveOnce(kind, recipe, outDir, takeName);
    } catch (e) {
      last = { ok: false, attempt, stage: "drive", error: String(e.message) };
      process.stderr.write(`  drive failed: ${e.message}\n`);
      continue;
    }

    let video = drive.video;
    if (!video) video = await stillsToVideo(drive.stills, path.join(outDir, `${takeName}.mp4`));

    // Hand the verify context to disk so an external gate (the pipeline, which
    // owns the real capture MP4) can run the SAME cascade without re-driving.
    if (a.emitContext) {
      await fs.writeFile(path.join(outDir, `${takeName}.expected.txt`), expected);
      await fs.writeFile(path.join(outDir, `${takeName}.signals.json`), JSON.stringify(drive.signals || {}));
    }

    if (!a.verify) {
      last = { ok: true, attempt, video, stills: drive.stills, verify: { skipped: true, reason: "--no-verify" } };
      break;
    }
    if (!video) {
      last = { ok: false, attempt, stage: "verify", error: "no video or stills to verify" };
      continue;
    }

    process.stderr.write(`  verifying (${video}) ...\n`);
    const verify = await verifyRecording({ video, expected, signals: drive.signals, frames: recipe.verifyFrames });
    process.stderr.write(`  verdict: ${verify.verdict}${verify.by ? " (" + verify.by + ")" : ""}${verify.skipped ? " — " + verify.reason : ""}\n`);

    if (verify.verdict === "pass" || verify.skipped) {
      last = { ok: true, attempt, video, stills: drive.stills, verify };
      break;
    }
    last = { ok: false, attempt, video, stills: drive.stills, verify };
    process.stderr.write(`  FAIL — ${(verify.reasons || []).join("; ")}\n`);
  }

  const manifest = {
    recipe: recipe.name,
    backend: kind,
    outDir,
    publishable: !!(last && last.ok),
    attempts: attempt,
    result: last,
    at: new Date().toISOString(),
  };
  const mPath = path.join(outDir, "manifest.json");
  await fs.writeFile(mPath, JSON.stringify(manifest, null, 2));
  process.stdout.write(JSON.stringify(manifest, null, 2) + "\n");
  process.exit(manifest.publishable ? 0 : 1);
}

main().catch((e) => {
  console.error("fatal:", e);
  process.exit(1);
});
